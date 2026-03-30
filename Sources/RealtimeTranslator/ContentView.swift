import SwiftUI
import Translation

struct ContentView: View {

    @State private var engine      = TranslatorEngine()
    @State private var showHistory = false

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
                header
                chatArea
                bottomBar
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(store: engine.store)
        }
        .translationTask(configENtoES) { engine.setSessionENtoES($0) }
        .translationTask(configEStoEN) { engine.setSessionEStoEN($0) }
        .task { _ = await engine.requestPermissions() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Historial
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }

            Spacer()

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text("🇺🇸").font(.title3)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.35))
                    Text("🇪🇸").font(.title3)
                }
                StatusCapsule(engine: engine)
            }

            Spacer()

            // Placeholder para centrar el título
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.1))
    }

    // MARK: - Chat area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if engine.messages.isEmpty && !engine.isListening {
                        emptyState
                    }
                    ForEach(engine.messages) { msg in
                        BubbleView(message: msg).id(msg.id)
                    }
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
            .onChange(of: engine.messages.count) {
                withAnimation { proxy.scrollTo(engine.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: engine.currentOriginal) {
                withAnimation { proxy.scrollTo("live", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.12))
            Text("Pulsa el micrófono\ny empieza a hablar")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if engine.isListening {
                HStack(spacing: 20) {
                    Label("EN → altavoz", systemImage: "speaker.wave.2")
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.65))
                    Label("ES → auriculares", systemImage: "airpodspro")
                        .font(.caption2)
                        .foregroundStyle(.green.opacity(0.65))
                }
            }

            if let err = engine.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }

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
            .scaleEffect(engine.isSpeaking ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: engine.isSpeaking)

            if !engine.isSessionReady {
                Text("Descargando modelos...").font(.caption2).foregroundStyle(.white.opacity(0.3))
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
            return engine.detectedLang == .english ? "Inglés detectado" : "Español detectado"
        }
        return "En pausa"
    }

    var dot: Color {
        if engine.isSpeaking  { return .orange }
        if engine.isListening { return engine.detectedLang == .english ? .blue : .green }
        return .gray
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.white.opacity(0.08))
        .clipShape(Capsule())
        .animation(.easeInOut, value: label)
    }
}

// MARK: - BubbleView

struct BubbleView: View {
    let message: TranslationMessage

    var isEN: Bool   { message.sourceLang == .english }
    var color: Color { isEN ? .blue : .green }

    var body: some View {
        VStack(alignment: isEN ? .leading : .trailing, spacing: 4) {
            HStack {
                if !isEN { Spacer() }
                Text((isEN ? "🇺🇸 " : "🇪🇸 ") + message.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.caption2).foregroundStyle(.white.opacity(0.28))
                if isEN { Spacer() }
            }
            HStack {
                if !isEN { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.original)
                        .font(.subheadline).foregroundStyle(.white)
                    Divider().background(color.opacity(0.3))
                    Text(message.translated)
                        .font(.subheadline.italic()).foregroundStyle(color.opacity(0.9))
                }
                .padding(12)
                .background(color.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.25), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                if isEN { Spacer(minLength: 40) }
            }
        }
    }
}

// MARK: - LiveBubble

struct LiveBubble: View {
    let original:   String
    let translated: String
    let lang:       TranslationMessage.DetectedLanguage

    var isEN:  Bool   { lang == .english }
    var color: Color  { isEN ? .blue : .green }

    var body: some View {
        HStack {
            if !isEN { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(original).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                if !translated.isEmpty {
                    Text(translated).font(.subheadline.italic()).foregroundStyle(color.opacity(0.65))
                }
            }
            .padding(12)
            .background(color.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.15), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if isEN { Spacer(minLength: 40) }
        }
    }
}

// MARK: - HistoryView

struct HistoryView: View {
    let store: ConversationStore
    @State private var selected: StoredConversation? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()

                if store.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.system(size: 48)).foregroundStyle(.white.opacity(0.12))
                        Text("Sin conversaciones guardadas")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.3))
                    }
                } else {
                    List {
                        ForEach(store.conversations) { conv in
                            Button { selected = conv } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conv.title)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)
                                    Text(conv.preview)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                    Text("\(conv.messages.count) mensajes")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.25))
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color(white: 0.12))
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Historial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }.foregroundStyle(.white)
                }
            }
            .sheet(item: $selected) { conv in
                ConversationDetailView(conversation: conv)
            }
        }
    }
}

// MARK: - ConversationDetailView

struct ConversationDetailView: View {
    let conversation: StoredConversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(conversation.messages) { msg in
                            StoredBubble(message: msg)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }
}

struct StoredBubble: View {
    let message: StoredMessage

    var isEN:  Bool   { message.sourceLang == "en" }
    var color: Color  { isEN ? .blue : .green }

    var body: some View {
        VStack(alignment: isEN ? .leading : .trailing, spacing: 4) {
            HStack {
                if !isEN { Spacer() }
                Text((isEN ? "🇺🇸 " : "🇪🇸 ") + message.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.caption2).foregroundStyle(.white.opacity(0.28))
                if isEN { Spacer() }
            }
            HStack {
                if !isEN { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.original).font(.subheadline).foregroundStyle(.white)
                    Divider().background(color.opacity(0.3))
                    Text(message.translated).font(.subheadline.italic()).foregroundStyle(color.opacity(0.9))
                }
                .padding(12)
                .background(color.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.25), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                if isEN { Spacer(minLength: 40) }
            }
        }
    }
}

#Preview {
    ContentView()
}
