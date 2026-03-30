import Foundation
import AVFoundation
import Speech
import Translation
import NaturalLanguage
import Observation

// MARK: - Live message model (UI)

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

    // History store
    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    // Two STT recognizers — same audio feed, different locale models
    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))!
    private var requestEN: SFSpeechAudioBufferRecognitionRequest?
    private var requestES: SFSpeechAudioBufferRecognitionRequest?
    private var taskEN:    SFSpeechRecognitionTask?
    private var taskES:    SFSpeechRecognitionTask?

    // Two translation sessions
    private var sessionENtoES: TranslationSession?
    private var sessionEStoEN: TranslationSession?

    private let audioEngine  = AVAudioEngine()
    private let synthesizer  = AVSpeechSynthesizer()
    private let langDetector = NLLanguageRecognizer()

    private var pendingEN = ""
    private var pendingES = ""

    // Delta tracking — only translate new words
    private var lastSourceTranslated  = ""
    private var lastDetectedLang: TranslationMessage.DetectedLanguage? = nil

    // Feedback-loop gate: block mic buffers while speaker TTS plays
    private var blockMicForSpeaker = false

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
        guard speech else { errorMessage = "Permiso de reconocimiento de voz denegado."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { errorMessage = "Permiso de micrófono denegado."; return false }
        return true
    }

    // MARK: - Sessions

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
        currentConversation = StoredConversation()   // nueva conversación
        messages = []

        let av = AVAudioSession.sharedInstance()

        // .voiceChat activa AEC por hardware (igual que las llamadas de teléfono)
        // Esto elimina el feedback del altavoz a nivel de DSP
        try av.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        try av.setActive(true)

        // API iOS 17+: forzar cancelación de eco si el hardware lo soporta
        if av.isEchoCancelledInputAvailable {
            try av.setPrefersEchoCancelledInput(true)
        }

        setupRequests()
        let input  = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Gate software: mientras el altavoz habla, no alimentamos los reconocedores
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, !self.blockMicForSpeaker else { return }
            self.requestEN?.append(buf)
            self.requestES?.append(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()
        launchENTask()
        launchESTask()
        isListening = true
    }

    func stopListening() {
        debounceTask?.cancel()
        store.upsert(currentConversation)            // guardar conversación al parar
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        requestEN?.endAudio(); taskEN?.cancel()
        requestES?.endAudio(); taskES?.cancel()
        requestEN = nil; requestES = nil
        taskEN    = nil; taskES    = nil
        isListening        = false
        blockMicForSpeaker = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - STT tasks

    private func setupRequests() {
        requestEN = SFSpeechAudioBufferRecognitionRequest()
        requestES = SFSpeechAudioBufferRecognitionRequest()
        requestEN?.shouldReportPartialResults = true
        requestES?.shouldReportPartialResults = true
    }

    private func launchENTask() {
        guard let req = requestEN else { return }
        taskEN = recognizerEN.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if isNoInputError(error) { Task { @MainActor in self.restartRecognition() }; return }
            guard let result else { return }
            let text    = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in
                self.pendingEN = text
                isFinal ? await self.pickAndTranslate(isFinal: true) : self.scheduleDebounce()
            }
        }
    }

    private func launchESTask() {
        guard let req = requestES else { return }
        taskES = recognizerES.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if isNoInputError(error) { return }
            guard let result else { return }
            let text    = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in
                self.pendingES = text
                isFinal ? await self.pickAndTranslate(isFinal: true) : self.scheduleDebounce()
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
            self.setupRequests()
            let input  = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMicForSpeaker else { return }
                self.requestEN?.append(buf)
                self.requestES?.append(buf)
            }
            self.launchENTask()
            self.launchESTask()
        }
    }

    // MARK: - Language detection + delta translation

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await pickAndTranslate(isFinal: false)
        }
    }

    private func pickAndTranslate(isFinal: Bool) async {
        guard !isTranslating else { return }

        let textEN = pendingEN
        let textES = pendingES
        guard !textEN.isEmpty || !textES.isEmpty else { return }

        langDetector.processString(textEN)
        let scoreEN = langDetector.languageHypotheses(withMaximum: 1)[.english] ?? 0
        langDetector.reset()
        langDetector.processString(textES)
        let scoreES = langDetector.languageHypotheses(withMaximum: 1)[.spanish] ?? 0
        langDetector.reset()

        let lang: TranslationMessage.DetectedLanguage
        let fullText: String

        if scoreEN >= scoreES && !textEN.isEmpty {
            lang = .english;  fullText = textEN
        } else if !textES.isEmpty {
            lang = .spanish;  fullText = textES
        } else { return }

        detectedLang    = lang
        currentOriginal = fullText

        if lang != lastDetectedLang {
            lastSourceTranslated = ""
            lastDetectedLang     = lang
            synthesizer.stopSpeaking(at: .immediate)
        }

        let delta     = computeDelta(full: fullText, translated: lastSourceTranslated)
        let wordCount = delta.split(separator: " ").count
        guard wordCount >= 3 || (isFinal && !delta.isEmpty) else { return }

        lastSourceTranslated = fullText
        await runTranslation(delta: delta, fullText: fullText, lang: lang, isFinal: isFinal)
    }

    private func computeDelta(full: String, translated: String) -> String {
        guard !translated.isEmpty else { return full }
        if full.hasPrefix(translated) {
            return String(full.dropFirst(translated.count)).trimmingCharacters(in: .whitespaces)
        }
        return full   // el STT corrigió el texto → retransmitir todo
    }

    private func runTranslation(delta: String, fullText: String,
                                lang: TranslationMessage.DetectedLanguage, isFinal: Bool) async {
        let session = lang == .english ? sessionENtoES : sessionEStoEN
        guard let session else { return }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(delta)
            let translated = result.targetText
            currentTranslated += (currentTranslated.isEmpty ? "" : " ") + translated

            if isFinal {
                let finalTranslated = currentTranslated
                messages.append(TranslationMessage(
                    original:   fullText,
                    translated: finalTranslated,
                    sourceLang: lang
                ))
                // Persistir en el historial
                currentConversation.messages.append(StoredMessage(
                    original:   fullText,
                    translated: finalTranslated,
                    sourceLang: lang == .english ? "en" : "es"
                ))
                store.upsert(currentConversation)

                currentOriginal      = ""
                currentTranslated    = ""
                lastSourceTranslated = ""
            }

            speakChunk(translated, lang: lang)
        } catch {
            print("Translation error: \(error)")
        }
    }

    // MARK: - TTS + audio routing

    private func speakChunk(_ text: String, lang: TranslationMessage.DetectedLanguage) {
        guard !text.isEmpty else { return }

        let av = AVAudioSession.sharedInstance()

        if lang == .english {
            // EN detectado → TTS en ES → altavoz (para quien no tiene auriculares)
            try? av.overrideOutputAudioPort(.speaker)
            blockMicForSpeaker = true   // gate software de backup
        } else {
            // ES detectado → TTS en EN → auriculares (no hay riesgo de feedback)
            try? av.overrideOutputAudioPort(.none)
            blockMicForSpeaker = false
        }

        let utterance   = AVSpeechUtterance(string: text)
        utterance.voice = lang == .english
            ? AVSpeechSynthesisVoice(language: "es-MX")
            : AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate * 1.1
        isSpeaking      = true
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TranslatorEngine: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !synthesizer.isSpeaking else { return }   // aún hay chunks en cola
            self.isSpeaking        = false
            // Pequeño margen antes de reabrir el mic (cola de eco residual)
            try? await Task.sleep(for: .milliseconds(200))
            self.blockMicForSpeaker = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking        = false
            self.blockMicForSpeaker = false
        }
    }
}

// MARK: - Helpers

private func isNoInputError(_ error: Error?) -> Bool {
    guard let e = error as NSError? else { return false }
    return e.domain == "kAFAssistantErrorDomain" && e.code == 1110
}
