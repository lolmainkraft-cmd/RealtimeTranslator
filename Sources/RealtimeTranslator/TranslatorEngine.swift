import Foundation
import AVFoundation
import Speech
import Translation
import Observation

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // MARK: - Published state
    var isListening    = false
    var isSessionReady = false
    var isSpeaking     = false
    var recognizedText = ""
    var translatedText = ""
    var errorMessage: String?

    // MARK: - Internal
    private(set) var textToTranslate = ""

    private let audioEngine      = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let synthesizer      = AVSpeechSynthesizer()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask:    SFSpeechRecognitionTask?
    private var translationSession: TranslationSession?

    private var lastSpokenText = ""
    private var debounceTask:  Task<Void, Never>?
    private var isTranslating  = false

    // MARK: - Init
    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Permissions
    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speech else {
            errorMessage = "Permiso de reconocimiento de voz denegado. Ve a Ajustes."
            return false
        }

        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else {
            errorMessage = "Permiso de micrófono denegado. Ve a Ajustes."
            return false
        }
        return true
    }

    // MARK: - Translation session (provided by ContentView via .translationTask)
    func setTranslationSession(_ session: TranslationSession) {
        translationSession = session
        isSessionReady = true
    }

    // MARK: - Start / Stop
    func startListening() throws {
        guard !isListening else { return }
        errorMessage = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        let inputNode = audioEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let error = error as NSError?,
               error.domain == "kAFAssistantErrorDomain",
               error.code == 1110 {
                // Silencio prolongado — normal, reiniciar
                Task { @MainActor in self.restartRecognition() }
                return
            }

            guard let result else { return }
            let text = result.bestTranscription.formattedString

            Task { @MainActor in
                self.recognizedText = text
                self.debounceTask?.cancel()

                if result.isFinal {
                    await self.scheduleTranslation(text)
                } else {
                    self.debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        guard !Task.isCancelled else { return }
                        await self.scheduleTranslation(text)
                    }
                }
            }
        }

        isListening = true
    }

    func stopListening() {
        debounceTask?.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask    = nil
        isListening        = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private helpers
    private func restartRecognition() {
        guard isListening else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask    = nil

        // Pequeña pausa antes de reiniciar
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            try? self.startListening()
        }
    }

    private func scheduleTranslation(_ text: String) async {
        guard !text.isEmpty, text != lastSpokenText, !isTranslating else { return }
        guard let session = translationSession else { return }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let response = try await session.translate(text)
            let translated = response.targetText
            translatedText = translated
            speak(translated)
        } catch {
            // Ignorar errores de traducción silenciosamente para no interrumpir el flujo
            print("Translation error: \(error)")
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty, text != lastSpokenText else { return }
        lastSpokenText = text

        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        // Voces de español disponibles en iOS: es-ES, es-MX, es-US
        utterance.voice  = AVSpeechSynthesisVoice(language: "es-MX") ?? AVSpeechSynthesisVoice(language: "es")
        utterance.rate   = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.volume = 1.0

        isSpeaking = true
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
