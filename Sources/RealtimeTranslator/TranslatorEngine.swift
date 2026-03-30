import Foundation
import AVFoundation
import Speech
import Translation
import Observation

// MARK: - Direction

enum TranslationDirection {
    case enToEs, esToEn
    var sourceLocale: String { self == .enToEs ? "en-US" : "es-MX" }
    var targetVoice:  String { self == .enToEs ? "es-MX" : "en-US" }
    var toggled: TranslationDirection { self == .enToEs ? .esToEn : .enToEs }
}

// MARK: - Message (par EN+ES)

struct TranslationMessage: Identifiable {
    let id         = UUID()
    let english:     String   // siempre el texto en inglés
    let spanish:     String   // siempre el texto en español
    let direction:   TranslationDirection
    let timestamp  = Date()
}

// MARK: - Engine

@Observable
@MainActor
final class TranslatorEngine: NSObject {

    // UI state
    var direction:    TranslationDirection = .enToEs
    var isListening   = false
    var isSessionReady = false
    var isSpeaking    = false
    var audioLevel:   Float = 0      // 0-1, para waveform

    // Paneles en vivo
    var liveEnglish   = ""
    var liveSpanish   = ""

    var messages:     [TranslationMessage] = []
    var errorMessage: String?

    // Historia persistente
    var store = ConversationStore()
    private var currentConversation = StoredConversation()

    // STT
    private let recognizerEN = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let recognizerES = SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))!
    private var activeRecognizer: SFSpeechRecognizer { direction == .enToEs ? recognizerEN : recognizerES }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task:    SFSpeechRecognitionTask?

    // Sesiones de traducción
    private var sessionENtoES: TranslationSession?
    private var sessionEStoEN: TranslationSession?
    private var activeSession: TranslationSession? { direction == .enToEs ? sessionENtoES : sessionEStoEN }

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    // Doble condición de chunking
    private var pendingText       = ""
    private var lastTextChange    = Date()
    private var silenceStart:     Date? = nil
    private var debounceTask:     Task<Void, Never>?

    // Gate feedback altavoz
    private var blockMic          = false
    private var isTranslating     = false

    private static let silenceDB:    Float = -40.0
    private static let minWords:     Int   = 4
    private static let textStableMs: Int   = 300
    private static let silenceMs:    Int   = 400

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

    // MARK: - Direction

    func setDirection(_ d: TranslationDirection) {
        guard d != direction else { return }
        let wasListening = isListening
        if wasListening { stopListening() }
        direction = d
        liveEnglish = ""; liveSpanish = ""
        if wasListening { try? startListening() }
    }

    // MARK: - Start / Stop

    func startListening() throws {
        guard !isListening else { return }
        errorMessage        = nil
        currentConversation = StoredConversation()
        messages            = []
        liveEnglish         = ""
        liveSpanish         = ""
        pendingText         = ""

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
            self.processAudioLevel(buf)
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
        isListening   = false
        blockMic      = false
        audioLevel    = 0
        silenceStart  = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio level + VAD

    private func processAudioLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        let db  = 20 * log10(max(rms, 1e-10))
        let level = Float(max(0, min(1, (db + 60) / 60)))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioLevel = level
            if db < Self.silenceDB {
                if self.silenceStart == nil { self.silenceStart = Date() }
            } else {
                self.silenceStart = nil
            }
        }
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
                self.pendingText    = text
                self.lastTextChange = Date()
                // Mostrar texto parcial en el panel activo
                if self.direction == .enToEs { self.liveEnglish = text }
                else                         { self.liveSpanish = text }

                self.debounceTask?.cancel()
                if isFinal {
                    await self.commitChunk(text, force: true)
                } else {
                    self.debounceTask = Task {
                        // Esperar estabilidad de texto (300ms)
                        try? await Task.sleep(for: .milliseconds(Self.textStableMs))
                        guard !Task.isCancelled else { return }
                        await self.commitChunk(text, force: false)
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
                self.processAudioLevel(buf)
            }
            self.launchTask()
        }
    }

    // MARK: - Doble condición de chunking

    private func commitChunk(_ text: String, force: Bool) async {
        guard !isTranslating else { return }
        let words = text.split(separator: " ").count
        guard words >= Self.minWords || force else { return }

        if !force {
            // Condición: silencio >= 400ms
            let silenceDuration = silenceStart.map { Date().timeIntervalSince($0) } ?? 0
            guard silenceDuration >= Double(Self.silenceMs) / 1000 else { return }
        }

        await translate(text)
    }

    // MARK: - Traducción

    private func translate(_ text: String) async {
        guard !text.isEmpty, !isTranslating else { return }
        guard let session = activeSession else { return }

        isTranslating    = true
        liveEnglish      = ""
        liveSpanish      = ""
        defer { isTranslating = false }

        do {
            let result     = try await session.translate(text)
            let translated = result.targetText

            let english = direction == .enToEs ? text : translated
            let spanish = direction == .enToEs ? translated : text

            let msg = TranslationMessage(english: english, spanish: spanish, direction: direction)
            messages.append(msg)

            currentConversation.messages.append(StoredMessage(
                original:   text,
                translated: translated,
                sourceLang: direction == .enToEs ? "en" : "es"
            ))
            store.upsert(currentConversation)

            speak(translated)
        } catch {
            print("Translation error: \(error)")
        }
    }

    // MARK: - TTS + routing

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .word)

        let av = AVAudioSession.sharedInstance()
        if direction == .enToEs {
            // Inglés hablado → TTS en español → AURICULARES (amigo español los lleva)
            // Sin riesgo de feedback → no bloqueamos el mic
            try? av.overrideOutputAudioPort(.none)
            blockMic = false
        } else {
            // Español hablado → TTS en inglés → ALTAVOZ (interlocutor inglés oye)
            // Riesgo de feedback → bloqueamos el mic mientras habla el altavoz
            try? av.overrideOutputAudioPort(.speaker)
            blockMic = true
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

// MARK: - RMS helper

private extension TranslatorEngine {
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return sqrt(sum / Float(n))
    }
}
