import Foundation
import AVFoundation
import WhisperKit
import Observation

// MARK: - WhisperTranscriber
// Wrapper de WhisperKit para transcripción de inglés on-device.
// Acepta buffers de AVAudioEngine, los resamplea a 16kHz y los transcribe.

@Observable
@MainActor
final class WhisperTranscriber {

    var isReady      = false
    var statusLabel  = "Cargando modelo Whisper..."

    private var whisper:     WhisperKit?
    private var sampleBuffer: [Float] = []

    // Mínimo de muestras para lanzar transcripción (0.8s @ 16kHz)
    private let minSamples = 12_800

    // MARK: - Setup

    func setup() async {
        do {
            // WhisperKit descarga el modelo desde HuggingFace la primera vez (~250MB)
            // y lo cachea en el dispositivo para siempre.
            whisper     = try await WhisperKit(model: "openai_whisper-small", verbose: false)
            isReady     = true
            statusLabel = ""
        } catch {
            statusLabel = "Error cargando Whisper: \(error.localizedDescription)"
            print("WhisperKit init error: \(error)")
        }
    }

    // MARK: - Audio input

    /// Recibe un buffer de AVAudioEngine (cualquier sample rate) y lo acumula a 16kHz.
    func append(_ buffer: AVAudioPCMBuffer) {
        let samples = resample(buffer, to: 16_000)
        sampleBuffer.append(contentsOf: samples)
    }

    func reset() { sampleBuffer = [] }

    var hasEnoughAudio: Bool { sampleBuffer.count >= minSamples }
    var bufferCount:    Int  { sampleBuffer.count }

    // MARK: - Transcripción

    /// Transcribe el buffer acumulado y lo limpia. Devuelve nil si el resultado es vacío o una alucinación.
    func transcribe() async -> String? {
        guard hasEnoughAudio, let whisper else { return nil }
        let samples = sampleBuffer
        sampleBuffer = []

        do {
            let results = try await whisper.transcribe(audioArray: samples)
            let raw = results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return isValidText(raw) ? raw : nil
        } catch {
            print("Whisper transcription error: \(error)")
            return nil
        }
    }

    // MARK: - Filtro anti-alucinaciones

    private func isValidText(_ text: String) -> Bool {
        guard text.count > 2 else { return false }
        // Whisper a veces alucina esto con silencio
        let hallucinations = ["thank you", "thanks for watching", "♪", "[ music", "[music", "applause", "subs by", "subtitles by"]
        let lower = text.lowercased()
        return !hallucinations.contains { lower.contains($0) }
    }

    // MARK: - Resampling AVAudioPCMBuffer → [Float] @ targetRate

    private func resample(_ buffer: AVAudioPCMBuffer, to targetRate: Double) -> [Float] {
        let srcRate = buffer.format.sampleRate

        // Si ya está a 16kHz y es mono float, devolver directamente
        if srcRate == targetRate,
           buffer.format.commonFormat == .pcmFormatFloat32,
           buffer.format.channelCount == 1,
           let data = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else { return [] }

        let ratio          = targetRate / srcRate
        let outFrameCount  = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)

        guard outFrameCount > 0,
              let outBuffer  = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrameCount),
              let converter  = AVAudioConverter(from: buffer.format, to: outFormat)
        else { return [] }

        var inputDone = false
        var convError: NSError?

        converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if !inputDone {
                inputDone = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard convError == nil,
              let channelData = outBuffer.floatChannelData?[0]
        else { return [] }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(outBuffer.frameLength)))
    }
}
