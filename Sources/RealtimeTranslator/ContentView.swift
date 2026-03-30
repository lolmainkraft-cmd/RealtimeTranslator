import SwiftUI
import Translation

struct ContentView: View {

    @State private var engine = TranslatorEngine()
    @State private var scrollProxy: ScrollViewProxy? = nil

    // Ambas sesiones se cargan al arrancar → modelos on-device descargados una vez
    private let configENtoES = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "es")
    )
    private let configEStoEN = TranslationSession.Configuration(
        source: Locale.Language(identifier: "es"),
        target: Locale.Language(identifier: "en")
    )

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Header ────────────────────────────────────────────────
                header

                // ── Chat history ──────────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if engine.messages.isEmpty {
                                emptyState
                            } else {
                                ForEach(engine.messages) { msg in
                                    BubbleView(message: msg)
                                        .id(msg.id)
                                }
                            }

                            // Live preview of current phrase
                            if engine.isListening && !engine.currentOriginal.isEmpty {
                                LiveBubble(
                                    original:   engine.currentOriginal,
                                    translated: engine.currentTranslated,
                                    lang:       engine.detectedLang
                                )
                                .id("live")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: engine.messages.count) {
                        withAnimation { proxy.scrollTo(engine.messages.last?.id, anchor: .bottom) }
                    }
                    .onChange(of: engine.currentOriginal) {
                        withAnimation { proxy.scrollTo("live", anchor: .bottom) }
                    }
                }

                // ── Bottom bar ────────────────────────────────────────────
                bottomBar
            }
        }
        .translationTask(configENtoES) { session in
            engine.setSessionENtoES(session)
        }
        .translationTask(configEStoEN) { session in
            engine.setSessionEStoEN(session)
        }
        .task {
            _ = await engine.requestPermissions()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("🇺🇸").font(.title3)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.4))
                Text("🇪🇸").font(.title3)
            }

            StatusCapsule(engine: engine)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.15))
            Text("Pulsa el micrófono y empieza a hablar\nen inglés o español")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Audio routing hint
            if engine.isListening {
                HStack(spacing: 16) {
                    Label("EN → altavoz", systemImage: "speaker.wave.2")
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.7))
                    Label("ES → auriculares", systemImage: "airpodspro")
                        .font(.caption2)
                        .foregroundStyle(.green.opacity(0.7))
                }
            }

            // Error
            if let err = engine.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Mic button
            Button {
                if engine.isListening { engine.stopListening() }
                else { try? engine.startListening() }
            } label: {
                ZStack {
                    Circle()
                        .fill(engine.isListening ? Color.red.opacity(0.15) : Color.white.opacity(0.1))
                        .frame(width: 72, height: 72)
                    Image(systemName: engine.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(engine.isListening ? .red : .white)
                }
            }
            .disabled(!engine.isSessionReady)
            .opacity(engine.isSessionReady ? 1 : 0.35)
            .buttonStyle(.plain)
            .scaleEffect(engine.isSpeaking ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: engine.isSpeaking)

            if !engine.isSessionReady {
                Text("Descargando modelos de traducción...")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1))
    }
}

// MARK: - StatusCapsule

struct StatusCapsule: View {
    let engine: TranslatorEngine

    var label: String {
        if !engine.isSessionReady { return "Preparando..." }
        if engine.isSpeaking      { return "Reproduciendo" }
        if engine.isListening {
            switch engine.detectedLang {
            case .english: return "Inglés detectado"
            case .spanish: return "Español detectado"
            }
        }
        return "En pausa"
    }

    var dot: Color {
        if engine.isSpeaking  { return .orange }
        if engine.isListening { return engine.detectedLang == .english ? .blue : .green }
        return .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.white.opacity(0.08))
        .clipShape(Capsule())
        .animation(.easeInOut, value: label)
    }
}

// MARK: - BubbleView (historial)

struct BubbleView: View {
    let message: TranslationMessage

    var isEN: Bool { message.sourceLang == .english }
    var accentColor: Color { isEN ? .blue : .green }
    var flag: String { isEN ? "🇺🇸" : "🇪🇸" }

    var body: some View {
        VStack(alignment: isEN ? .leading : .trailing, spacing: 4) {
            // Flag + timestamp
            HStack {
                if !isEN { Spacer() }
                Text(flag + " " + message.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
                if isEN { Spacer() }
            }

            HStack {
                if !isEN { Spacer(minLength: 40) }

                VStack(alignment: .leading, spacing: 6) {
                    // Original
                    Text(message.original)
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    Divider().background(accentColor.opacity(0.3))

                    // Translated
                    Text(message.translated)
                        .font(.subheadline.italic())
                        .foregroundStyle(accentColor.opacity(0.9))
                }
                .padding(12)
                .background(accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(accentColor.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if isEN { Spacer(minLength: 40) }
            }
        }
    }
}

// MARK: - LiveBubble (frase en curso)

struct LiveBubble: View {
    let original:   String
    let translated: String
    let lang:       TranslationMessage.DetectedLanguage

    var isEN: Bool { lang == .english }
    var color: Color { isEN ? .blue : .green }

    var body: some View {
        HStack {
            if !isEN { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 4) {
                Text(original)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                if !translated.isEmpty {
                    Text(translated)
                        .font(.subheadline.italic())
                        .foregroundStyle(color.opacity(0.7))
                }
            }
            .padding(12)
            .background(color.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(color.opacity(0.15), lineWidth: 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: original)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if isEN { Spacer(minLength: 40) }
        }
    }
}

#Preview {
    ContentView()
}
