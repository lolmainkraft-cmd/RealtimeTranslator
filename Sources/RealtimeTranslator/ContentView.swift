import SwiftUI
import Translation

struct ContentView: View {

    @State private var engine = TranslatorEngine()

    // Configuración fija: la sesión se crea una vez y se reutiliza
    private let translationConfig = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "es")
    )

    var body: some View {
        ZStack {
            // Fondo degradado oscuro
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {

                // ── Cabecera ──────────────────────────────────────────────
                VStack(spacing: 4) {
                    Text("Traductor en Vivo")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Inglés → Español")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 16)

                // ── Estado ────────────────────────────────────────────────
                StatusCapsule(engine: engine)

                // ── Tarjeta: Inglés (STT) ─────────────────────────────────
                TranscriptCard(
                    flag:  "🇺🇸",
                    label: "Inglés",
                    text:  engine.recognizedText,
                    color: .blue
                )

                // ── Tarjeta: Español (traducción) ──────────────────────────
                TranscriptCard(
                    flag:  "🇪🇸",
                    label: "Español",
                    text:  engine.translatedText,
                    color: .green
                )

                Spacer()

                // ── Error ─────────────────────────────────────────────────
                if let msg = engine.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // ── Botón principal ────────────────────────────────────────
                MicButton(engine: engine)

                // ── Hint auriculares ───────────────────────────────────────
                if engine.isListening {
                    Text("Usa auriculares para evitar eco")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                }

                Spacer().frame(height: 8)
            }
            .padding(.horizontal, 20)
        }
        // Obtener la sesión de traducción on-device al arrancar la app
        .translationTask(translationConfig) { session in
            engine.setTranslationSession(session)
        }
        .task {
            _ = await engine.requestPermissions()
        }
    }
}

// MARK: - Subviews

struct StatusCapsule: View {
    let engine: TranslatorEngine

    var label: String {
        if !engine.isSessionReady { return "Preparando traductor..." }
        if engine.isSpeaking      { return "Traduciendo..." }
        if engine.isListening     { return "Escuchando..." }
        return "Listo"
    }

    var dotColor: Color {
        if engine.isSpeaking  { return .orange }
        if engine.isListening { return .green }
        return .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .opacity(engine.isListening || engine.isSpeaking ? 1 : 0.4)
                .animation(
                    engine.isListening
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: engine.isListening
                )

            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08))
        .clipShape(Capsule())
        .animation(.easeInOut, value: label)
    }
}

struct TranscriptCard: View {
    let flag:  String
    let label: String
    let text:  String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(flag)
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(color)
            }

            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.body)
                    .foregroundStyle(text.isEmpty ? .white.opacity(0.25) : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: text)
            }
            .frame(maxHeight: 110)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct MicButton: View {
    let engine: TranslatorEngine

    var body: some View {
        Button {
            if engine.isListening {
                engine.stopListening()
            } else {
                guard engine.isSessionReady else { return }
                try? engine.startListening()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(engine.isListening ? Color.red.opacity(0.15) : Color.white.opacity(0.1))
                    .frame(width: 90, height: 90)

                Image(systemName: engine.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(engine.isListening ? .red : .white)
            }
        }
        .disabled(!engine.isSessionReady)
        .opacity(engine.isSessionReady ? 1 : 0.4)
        .scaleEffect(engine.isListening ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: engine.isListening)
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
