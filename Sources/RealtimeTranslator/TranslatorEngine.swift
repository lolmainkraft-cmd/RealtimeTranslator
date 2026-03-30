import Foundation
import AVFoundation
import Speech
import Translation
import Observation

// MARK: - Models

enum ActiveMic { case none, english, spanish }

struct TranslationMessage: Identifiable {
    let id        = UUID()
    let english:    String
    let spanish:    String
    let timestamp = Date()
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // UI state
    var activeMic:  ActiveMic = .none
    var isSpeaking  = false
    var isReady     = false
    var audioLevel: Float = 0

    // Paneles en vivo
    var liveEnglish = ""
    var liveSpanish = ""
    var messages:   [TranslationMessage] = []
    var errorMessage: String?

    // Historia
    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    // STT
    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))!
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task:    SFSpeechRecognitionTask?

    // Sesiones
    private var sessionENtoES: TranslationSession?
    private var sessionEStoEN: TranslationSession?

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    // Chunking streaming (mic inglés)
    private var streamedUpTo    = ""   // texto ya traducido en modo streaming
    private var silenceStart:   Date?  = nil
    private var lastTextChange  = Date()
    private var debounceTask:   Task<Void, Never>?

    private var blockMic        = false
    private var isTranslating   = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { errorMessage = "Permiso de micrófono denegado."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { errorMessage = "Permiso de micrófono denegado."; return false }
        return true
    }

    func setSessionENtoES(_ s: TranslationSession) { sessionENtoES = s; isReady = sessionEStoEN != nil }
    func setSessionEStoEN(_ s: TranslationSession) { sessionEStoEN = s; isReady = sessionENtoES != nil }

    // MARK: - Mic buttons

    func tapEnglishMic() {
        if activeMic == .english { stopListening(); return }
        stopListening()
        activeMic = .english
        try? startListening(recognizer: recognizerEN)
    }

    func tapSpanishMic() {
        if activeMic == .spanish { stopListening(); return }
        stopListening()
        activeMic = .spanish
        try? startListening(recognizer: recognizerES)
    }

    // MARK: - Audio engine

    private func startListening(recognizer: SFSpeechRecognizer) throws {
        streamedUpTo  = ""
        liveEnglish   = ""
        liveSpanish   = ""
        currentConversation = StoredConversation()

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
            self.updateAudioLevel(buf)
        }

        audioEngine.prepare()
        try audioEngine.start()
        launchTask(recognizer: recognizer)
    }

    func stopListening() {
        debounceTask?.cancel()
        if activeMic != .none { store.upsert(currentConversation) }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil
        activeMic    = .none
        blockMic     = false
        audioLevel   = 0
        silenceStart = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - STT task

    private func launchTask(recognizer: SFSpeechRecognizer) {
        guard let req = request else { return }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if (error as NSError?)?.code == 1110 {
                Task { @MainActor in self.handleSilenceTimeout() }
                return
            }
            guard let result else { return }
            let text    = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in self.onText(text, isFinal: isFinal) }
        }
    }

    private func handleSilenceTimeout() {
        // Reiniciar reconocedor
        guard activeMic != .none else { return }
        let mic = activeMic
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil

        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard self.activeMic == mic else { return }
            self.request = SFSpeechAudioBufferRecognitionRequest()
            self.request?.shouldReportPartialResults = true
            let input  = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMic else { return }
                self.request?.append(buf)
                self.updateAudioLevel(buf)
            }
            let recognizer = mic == .english ? self.recognizerEN : self.recognizerES
            self.launchTask(recognizer: recognizer)
        }
    }

    // MARK: - Texto entrante

    private func onText(_ text: String, isFinal: Bool) {
        lastTextChange = Date()

        // Mostrar parcial en panel activo
        if activeMic == .english { liveEnglish = text }
        else                      { liveSpanish = text }

        debounceTask?.cancel()

        if activeMic == .english {
            // MODO STREAMING: traduce chunks a medida que llegan
            if isFinal {
                debounceTask = Task { await self.streamChunk(text, force: true) }
            } else {
                debounceTask = Task {
                    // Esperar estabilidad de texto (250ms)
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    // + silencio de voz >= 350ms
                    let silence = self.silenceStart.map { Date().timeIntervalSince($0) } ?? 0
                    guard silence >= 0.35 else { return }
                    await self.streamChunk(text, force: false)
                }
            }
        } else {
            // MODO FRASE COMPLETA: esperar a que termine
            if isFinal {
                debounceTask = Task { await self.translateFull(text) }
            } else {
                // Fallback: 1.5s de silencio total si isFinal tarda
                debounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled else { return }
                    let silence = self.silenceStart.map { Date().timeIntervalSince($0) } ?? 0
                    if silence >= 1.2 { await self.translateFull(text) }
                }
            }
        }
    }

    // MARK: - Streaming EN→ES (chunks en AirPods)

    private func streamChunk(_ text: String, force: Bool) async {
        guard !isTranslating, activeMic == .english else { return }
        guard let session = sessionENtoES else { return }

        // Calcular delta (solo palabras nuevas)
        let delta: String
        if text.hasPrefix(streamedUpTo) {
            delta = String(text.dropFirst(streamedUpTo.count)).trimmingCharacters(in: .whitespaces)
        } else {
            delta = text   // STT corrigió → retransmitir todo
            streamedUpTo  = ""
        }

        let words = delta.split(separator: " ").count
        guard words >= 3 || (force && !delta.isEmpty) else { return }

        streamedUpTo  = text
        isTranslating = true
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(delta)
            let translated = result.targetText
            liveSpanish   += (liveSpanish.isEmpty ? "" : " ") + translated

            if force {
                // isFinal → guardar mensaje completo
                let english = liveEnglish
                let spanish = liveSpanish
                messages.append(TranslationMessage(english: english, spanish: spanish))
                currentConversation.messages.append(StoredMessage(
                    original: english, translated: spanish, sourceLang: "en"
                ))
                store.upsert(currentConversation)
                liveEnglish  = ""
                liveSpanish  = ""
                streamedUpTo = ""
            }

            // TTS en español → AirPods (sin bloquear mic, no hay feedback)
            speakChunk(translated, voice: "es-MX", toSpeaker: false)
        } catch { print("Stream error: \(error)") }
    }

    // MARK: - Frase completa ES→EN (altavoz)

    private func translateFull(_ text: String) async {
        guard !isTranslating, activeMic == .spanish, !text.isEmpty else { return }
        guard let session = sessionEStoEN else { return }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(text)
            let translated = result.targetText

            messages.append(TranslationMessage(english: translated, spanish: text))
            currentConversation.messages.append(StoredMessage(
                original: text, translated: translated, sourceLang: "es"
            ))
            store.upsert(currentConversation)
            liveSpanish = ""
            liveEnglish = ""

            // TTS en inglés → altavoz → bloquear mic mientras habla
            speakChunk(translated, voice: "en-US", toSpeaker: true)
        } catch { print("Full translate error: \(error)") }
    }

    // MARK: - TTS

    private func speakChunk(_ text: String, voice: String, toSpeaker: Bool) {
        guard !text.isEmpty else { return }
        let av = AVAudioSession.sharedInstance()
        if toSpeaker {
            try? av.overrideOutputAudioPort(.speaker)
            blockMic = true        // gate: mic cerrado mientras habla el altavoz
        } else {
            try? av.overrideOutputAudioPort(.none)  // AirPods/auriculares
            blockMic = false
        }
        let u       = AVSpeechUtterance(string: text)
        u.voice     = AVSpeechSynthesisVoice(language: voice)
        u.rate      = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking  = true
        synthesizer.speak(u)   // encola automáticamente
    }

    // MARK: - Audio level / VAD

    private func updateAudioLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let db  = 20 * log10(max(rms, 1e-10))
        let lvl = Float(max(0, min(1, (db + 60) / 60)))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioLevel = lvl
            if db < -40 {
                if self.silenceStart == nil { self.silenceStart = Date() }
            } else {
                self.silenceStart = nil
            }
        }
    }
}

// MARK: - Delegate

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
