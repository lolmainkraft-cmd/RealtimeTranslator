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
    var activeMic:   ActiveMic = .none
    var isSpeaking   = false
    var isReady      = false
    var audioLevel:  Float = 0
    var statusLabel  = ""

    // Paneles en vivo
    var liveEnglish  = ""
    var liveSpanish  = ""
    var messages:    [TranslationMessage] = []
    var errorMessage: String?

    // Whisper (mic inglés)
    let whisper = WhisperTranscriber()

    // SFSpeechRecognizer (mic español)
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))!
    private var requestES:   SFSpeechAudioBufferRecognitionRequest?
    private var taskES:      SFSpeechRecognitionTask?

    // Sesiones de traducción
    private var sessionENtoES: TranslationSession?
    private var sessionEStoEN: TranslationSession?

    // Historia
    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    // VAD + chunking
    private var silenceStart:   Date? = nil
    private var debounceTask:   Task<Void, Never>?
    private var blockMic        = false
    private var isTranslating   = false

    // Streaming EN: delta tracking
    private var streamedSoFar   = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Boot

    func boot() async {
        _ = await requestPermissions()
        // Cargar Whisper en paralelo con el resto del setup
        await whisper.setup()
        updateReadyState()
    }

    private func updateReadyState() {
        isReady     = whisper.isReady && sessionENtoES != nil && sessionEStoEN != nil
        statusLabel = whisper.isReady ? whisper.statusLabel : whisper.statusLabel
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { errorMessage = "Permiso de reconocimiento de voz denegado."; return false }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { errorMessage = "Permiso de micrófono denegado."; return false }
        return true
    }

    // MARK: - Translation sessions

    func setSessionENtoES(_ s: TranslationSession) { sessionENtoES = s; updateReadyState() }
    func setSessionEStoEN(_ s: TranslationSession) { sessionEStoEN = s; updateReadyState() }

    // MARK: - Mic buttons

    func tapEnglishMic() {
        if activeMic == .english { stopListening(); return }
        stopListening()
        activeMic = .english
        tryStart()
    }

    func tapSpanishMic() {
        if activeMic == .spanish { stopListening(); return }
        stopListening()
        activeMic = .spanish
        tryStart()
    }

    private func tryStart() {
        do { try startAudio() }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Audio engine

    private func startAudio() throws {
        liveEnglish  = ""
        liveSpanish  = ""
        streamedSoFar = ""
        whisper.reset()
        currentConversation = StoredConversation()

        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        try av.setActive(true)
        if #available(iOS 18.2, *), av.isEchoCancelledInputAvailable {
            try av.setPrefersEchoCancelledInput(true)
        }

        let input  = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        if activeMic == .spanish {
            // Español: SFSpeechRecognizer como antes
            requestES = SFSpeechAudioBufferRecognitionRequest()
            requestES?.shouldReportPartialResults = true

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMic else { return }
                self.requestES?.append(buf)
                self.updateLevel(buf)
            }
            launchSpanishTask()
        } else {
            // Inglés: Whisper
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMic else { return }
                self.whisper.append(buf)
                self.updateLevel(buf)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopListening() {
        debounceTask?.cancel()
        if activeMic != .none { store.upsert(currentConversation) }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        requestES?.endAudio(); taskES?.cancel()
        requestES = nil; taskES = nil
        whisper.reset()
        activeMic    = .none
        blockMic     = false
        audioLevel   = 0
        silenceStart = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio level / VAD

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
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

            let isSilent = db < -40
            if isSilent {
                if self.silenceStart == nil {
                    self.silenceStart = Date()
                    // Silencio detectado → programar transcripción/traducción
                    if self.activeMic == .english { self.scheduleWhisperChunk() }
                }
            } else {
                self.silenceStart = nil
                // Cancelar debounce mientras hay voz activa
                if self.activeMic == .english {
                    self.debounceTask?.cancel()
                    self.liveEnglish = "Escuchando..."
                }
            }
        }
    }

    // MARK: - Inglés: Whisper streaming por chunks

    private func scheduleWhisperChunk() {
        debounceTask?.cancel()
        debounceTask = Task {
            // Esperar 400ms de silencio confirmado
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self.activeMic == .english else { return }
            guard self.whisper.hasEnoughAudio else { self.liveEnglish = ""; return }

            self.liveEnglish = "Transcribiendo..."
            guard let text = await self.whisper.transcribe(), !text.isEmpty else {
                self.liveEnglish = ""
                return
            }

            self.liveEnglish = text
            await self.handleEnglishText(text)
        }
    }

    private func handleEnglishText(_ text: String) async {
        guard !isTranslating, activeMic == .english else { return }
        guard let session = sessionENtoES else { return }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(text)
            let translated = result.targetText
            liveSpanish   += (liveSpanish.isEmpty ? "" : " ") + translated

            // Guardar en historial
            messages.append(TranslationMessage(english: text, spanish: translated))
            currentConversation.messages.append(StoredMessage(
                original: text, translated: translated, sourceLang: "en"
            ))
            store.upsert(currentConversation)
            liveEnglish = ""
            liveSpanish = ""

            // TTS en español → AirPods (sin bloquear mic)
            speak(translated, voice: "es-MX", toSpeaker: false)
        } catch { print("EN translation error: \(error)") }
    }

    // MARK: - Español: SFSpeechRecognizer → frase completa → altavoz

    private func launchSpanishTask() {
        guard let req = requestES else { return }
        taskES = recognizerES.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if (error as NSError?)?.code == 1110 {
                Task { @MainActor in self.restartSpanishTask() }
                return
            }
            guard let result else { return }
            let text    = result.bestTranscription.formattedString
            let isFinal = result.isFinal

            Task { @MainActor in
                self.liveSpanish = text
                self.debounceTask?.cancel()

                if isFinal {
                    self.debounceTask = Task { await self.handleSpanishFull(text) }
                } else {
                    self.debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard !Task.isCancelled else { return }
                        let silence = self.silenceStart.map { Date().timeIntervalSince($0) } ?? 0
                        if silence >= 1.2 { await self.handleSpanishFull(text) }
                    }
                }
            }
        }
    }

    private func restartSpanishTask() {
        guard activeMic == .spanish else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        requestES?.endAudio(); taskES?.cancel()
        requestES = nil; taskES = nil

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard self.activeMic == .spanish else { return }
            self.requestES = SFSpeechAudioBufferRecognitionRequest()
            self.requestES?.shouldReportPartialResults = true
            let input  = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self, !self.blockMic else { return }
                self.requestES?.append(buf)
                self.updateLevel(buf)
            }
            self.launchSpanishTask()
        }
    }

    private func handleSpanishFull(_ text: String) async {
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

            // TTS en inglés → altavoz → gate mic
            speak(translated, voice: "en-US", toSpeaker: true)
        } catch { print("ES translation error: \(error)") }
    }

    // MARK: - TTS

    private func speak(_ text: String, voice: String, toSpeaker: Bool) {
        guard !text.isEmpty else { return }
        let av = AVAudioSession.sharedInstance()
        if toSpeaker {
            try? av.overrideOutputAudioPort(.speaker)
            blockMic = true
        } else {
            try? av.overrideOutputAudioPort(.none)
            blockMic = false
        }
        let u      = AVSpeechUtterance(string: text)
        u.voice    = AVSpeechSynthesisVoice(language: voice)
        u.rate     = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(u)
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
