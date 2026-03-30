import Foundation
import AVFoundation
import Speech
import Translation
import NaturalLanguage
import Observation

// MARK: - Message model

struct TranslationMessage: Identifiable {
    let id         = UUID()
    let original:    String
    let translated:  String
    let sourceLang:  DetectedLanguage
    let timestamp  = Date()

    enum DetectedLanguage { case english, spanish }
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // Public state
    var isListening    = false
    var isSessionReady = false
    var isSpeaking     = false
    var currentOriginal   = ""
    var currentTranslated = ""
    var detectedLang: TranslationMessage.DetectedLanguage = .english
    var messages: [TranslationMessage] = []
    var errorMessage: String?

    // Two STT recognizers — same audio, different locale models
    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))!
    private var requestEN: SFSpeechAudioBufferRecognitionRequest?
    private var requestES: SFSpeechAudioBufferRecognitionRequest?
    private var taskEN:    SFSpeechRecognitionTask?
    private var taskES:    SFSpeechRecognitionTask?

    // Two translation sessions (both loaded at startup)
    private var sessionENtoES: TranslationSession?
    private var sessionEStoEN: TranslationSession?

    private let audioEngine  = AVAudioEngine()
    private let synthesizer  = AVSpeechSynthesizer()
    private let langDetector = NLLanguageRecognizer()

    private var pendingEN    = ""
    private var pendingES    = ""
    private var lastSpoken   = ""
    private var isTranslating = false
    private var debounceTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { errorMessage = "Permiso de reconocimiento de voz denegado. Ve a Ajustes."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic    else { errorMessage = "Permiso de micrófono denegado. Ve a Ajustes."; return false }
        return true
    }

    // MARK: - Translation sessions

    func setSessionENtoES(_ session: TranslationSession) {
        sessionENtoES = session
        isSessionReady = sessionEStoEN != nil
    }

    func setSessionEStoEN(_ session: TranslationSession) {
        sessionEStoEN = session
        isSessionReady = sessionENtoES != nil
    }

    // MARK: - Start / Stop

    func startListening() throws {
        guard !isListening else { return }
        errorMessage = nil

        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .measurement,
                           options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
        try av.setActive(true)

        requestEN = SFSpeechAudioBufferRecognitionRequest()
        requestES = SFSpeechAudioBufferRecognitionRequest()
        requestEN?.shouldReportPartialResults = true
        requestES?.shouldReportPartialResults = true

        let input  = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        // One tap → both recognizers receive the same audio
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.requestEN?.append(buf)
            self?.requestES?.append(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()

        launchENTask()
        launchESTask()
        isListening = true
    }

    func stopListening() {
        debounceTask?.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        requestEN?.endAudio(); taskEN?.cancel()
        requestES?.endAudio(); taskES?.cancel()
        requestEN = nil; requestES = nil
        taskEN    = nil; taskES    = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - STT tasks

    private func launchENTask() {
        guard let req = requestEN else { return }
        taskEN = recognizerEN.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if isNoInputError(error) {
                Task { @MainActor in self.restartRecognition() }
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in
                self.pendingEN = text
                if result.isFinal { await self.pickAndTranslate() }
                else              { self.scheduleDebounce() }
            }
        }
    }

    private func launchESTask() {
        guard let req = requestES else { return }
        taskES = recognizerES.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if isNoInputError(error) { return } // EN task handles restart
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in
                self.pendingES = text
                if result.isFinal { await self.pickAndTranslate() }
                else              { self.scheduleDebounce() }
            }
        }
    }

    private func restartRecognition() {
        guard isListening else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        requestEN?.endAudio(); taskEN?.cancel()
        requestES?.endAudio(); taskES?.cancel()
        requestEN = nil; requestES = nil; taskEN = nil; taskES = nil

        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard self.isListening else { return }
            let input  = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            self.requestEN = SFSpeechAudioBufferRecognitionRequest()
            self.requestES = SFSpeechAudioBufferRecognitionRequest()
            self.requestEN?.shouldReportPartialResults = true
            self.requestES?.shouldReportPartialResults = true
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                self?.requestEN?.append(buf)
                self?.requestES?.append(buf)
            }
            self.launchENTask()
            self.launchESTask()
        }
    }

    // MARK: - Language detection

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await pickAndTranslate()
        }
    }

    private func pickAndTranslate() async {
        guard !isTranslating else { return }

        let textEN = pendingEN
        let textES = pendingES
        guard !textEN.isEmpty || !textES.isEmpty else { return }

        // Score each candidate with NLLanguageRecognizer
        langDetector.processString(textEN)
        let scoreEN = langDetector.languageHypotheses(withMaximum: 1)[.english] ?? 0
        langDetector.reset()

        langDetector.processString(textES)
        let scoreES = langDetector.languageHypotheses(withMaximum: 1)[.spanish] ?? 0
        langDetector.reset()

        if scoreEN >= scoreES && !textEN.isEmpty {
            detectedLang   = .english
            currentOriginal = textEN
            await runTranslation(text: textEN, lang: .english)
        } else if !textES.isEmpty {
            detectedLang   = .spanish
            currentOriginal = textES
            await runTranslation(text: textES, lang: .spanish)
        }
    }

    private func runTranslation(text: String, lang: TranslationMessage.DetectedLanguage) async {
        guard text != lastSpoken, !text.isEmpty else { return }
        let session = lang == .english ? sessionENtoES : sessionEStoEN
        guard let session else { return }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(text)
            let translated = result.targetText
            currentTranslated = translated
            messages.append(TranslationMessage(original: text, translated: translated, sourceLang: lang))
            speak(translated, lang: lang)
        } catch {
            print("Translation error: \(error)")
        }
    }

    // MARK: - TTS + audio routing

    private func speak(_ text: String, lang: TranslationMessage.DetectedLanguage) {
        guard !text.isEmpty, text != lastSpoken else { return }
        lastSpoken = text
        synthesizer.stopSpeaking(at: .immediate)

        let av = AVAudioSession.sharedInstance()
        if lang == .english {
            // Inglés detectado → traducción en español → sale por ALTAVOZ
            // (para que la persona que no tiene AirPods oiga la traducción)
            try? av.overrideOutputAudioPort(.speaker)
        } else {
            // Español detectado → traducción en inglés → sale por AURICULARES
            // (para que quien lleva AirPods oiga la traducción)
            try? av.overrideOutputAudioPort(.none)
        }

        let utterance       = AVSpeechUtterance(string: text)
        utterance.voice     = lang == .english
            ? AVSpeechSynthesisVoice(language: "es-MX")
            : AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate      = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.volume    = 1.0
        isSpeaking          = true
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TranslatorEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

// MARK: - Helpers

private func isNoInputError(_ error: Error?) -> Bool {
    guard let e = error as NSError? else { return false }
    return e.domain == "kAFAssistantErrorDomain" && e.code == 1110
}
