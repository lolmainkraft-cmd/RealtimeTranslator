import Foundation
import AVFoundation
import Speech
import Translation
import Observation

// MARK: - Direction

enum TranslationDirection {
    case enToEs, esToEn

    var sourceLocale: String  { self == .enToEs ? "en-US" : "es-MX" }
    var targetVoice:  String  { self == .enToEs ? "es-MX" : "en-US" }
    var label:        String  { self == .enToEs ? "🇺🇸 → 🇪🇸" : "🇪🇸 → 🇺🇸" }
    var toggled: TranslationDirection { self == .enToEs ? .esToEn : .enToEs }
}

// MARK: - Live message

struct TranslationMessage: Identifiable {
    let id         = UUID()
    let original:    String
    let translated:  String
    let direction:   TranslationDirection
    let timestamp  = Date()
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    var direction:     TranslationDirection = .enToEs
    var isListening    = false
    var isSessionReady = false
    var isSpeaking     = false
    var currentOriginal   = ""
    var currentTranslated = ""
    var messages:    [TranslationMessage] = []
    var errorMessage: String?

    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))!
    private var activeRecognizer: SFSpeechRecognizer { direction == .enToEs ? recognizerEN : recognizerES }

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task:    SFSpeechRecognitionTask?

    private var sessionENtoES: TranslationSession?
    private var sessionEStoEN: TranslationSession?
    private var activeSession: TranslationSession? { direction == .enToEs ? sessionENtoES : sessionEStoEN }

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    private var lastTranslated   = ""
    private var blockMic         = false
    private var isTranslating    = false
    private var debounceTask:    Task<Void, Never>?

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

    func setSessionENtoES(_ s: TranslationSession) { sessionENtoES = s; checkReady() }
    func setSessionEStoEN(_ s: TranslationSession) { sessionEStoEN = s; checkReady() }
    private func checkReady() { isSessionReady = sessionENtoES != nil && sessionEStoEN != nil }

    // MARK: - Direction toggle

    func toggleDirection() {
        let wasListening = isListening
        if wasListening { stopListening() }
        direction      = direction.toggled
        lastTranslated = ""
        if wasListening { try? startListening() }
    }

    // MARK: - Start / Stop

    func startListening() throws {
        guard !isListening else { return }
        errorMessage        = nil
        currentConversation = StoredConversation()
        messages            = []
        lastTranslated      = ""

        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        try av.setActive(true)
        if #available(iOS 18.2, *), av.isEchoCancelledInputAvailable {
            try av.setPrefersEchoCancelledInput(true)
        }

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true

        let input  = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, !self.blockMic else { return }
            self.request?.append(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()
        launchTask()
        isListening = true
    }

    func stopListening() {
        debounceTask?.cancel()
        store.upsert(currentConversation)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil
        isListening = false
        blockMic    = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - STT task

    private func launchTask() {
        guard let req = request else { return }
        task = activeRecognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if (error as NSError?)?.code == 1110 {
                Task { @MainActor in self.restartTask() }
                return
            }
            guard let result else { return }
            let text    = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in
                self.currentOriginal = text
                self.debounceTask?.cancel()
                if isFinal {
                    await self.translate(text)
                } else {
                    self.debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        guard !Task.isCancelled else { return }
                        await self.translate(text)
                    }
                }
            }
        }
    }

    private func restartTask() {
        guard isListening else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard self.isListening else { return }
            self.request = SFSpeechAudioBufferRecognitionRequest()
            self.request?.shouldReportPartialResults = true
            let input  = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMic else { return }
                self.request?.append(buf)
            }
            self.launchTask()
        }
    }

    // MARK: - Translation

    private func translate(_ text: String) async {
        guard !text.isEmpty, text != lastTranslated, !isTranslating else { return }
        guard let session = activeSession else { return }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(text)
            let translated = result.targetText
            currentTranslated = translated
            lastTranslated    = text

            let msg = TranslationMessage(original: text, translated: translated, direction: direction)
            messages.append(msg)

            currentConversation.messages.append(StoredMessage(
                original:   text,
                translated: translated,
                sourceLang: direction == .enToEs ? "en" : "es"
            ))
            store.upsert(currentConversation)

            currentOriginal   = ""
            currentTranslated = ""

            speak(translated)
        } catch {
            print("Translation error: \(error)")
        }
    }

    // MARK: - TTS

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let av = AVAudioSession.sharedInstance()
        // EN→ES: traducción en español → altavoz (interlocutor sin auriculares)
        // ES→EN: traducción en inglés  → auriculares (sin riesgo de feedback)
        if direction == .enToEs {
            try? av.overrideOutputAudioPort(.speaker)
            blockMic = true
        } else {
            try? av.overrideOutputAudioPort(.none)
            blockMic = false
        }

        let utterance   = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: direction.targetVoice)
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking      = true
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TranslatorEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            guard !synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            try? await Task.sleep(for: .milliseconds(250))
            self.blockMic = false
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.blockMic = false }
    }
}
