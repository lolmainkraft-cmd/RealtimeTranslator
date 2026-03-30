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
        HStack(spacing: 12) {

            // Botón historial
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // Botón de dirección — toca para cambiar
            Button { engine.toggleDirection() } label: {
                HStack(spacing: 8) {
                    Text(engine.direction.label)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.trianglehead.swap")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(engine.direction == .enToEs ? Color.blue.opacity(0.25) : Color.green.opacity(0.25))
                )
                .overlay(
                    Capsule().stroke(
                        engine.direction == .enToEs ? Color.blue.opacity(0.4) : Color.green.opacity(0.4),
                        lineWidth: 1
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(!engine.isSessionReady)
            .animation(.easeInOut(duration: 0.2), value: engine.direction)

            Spacer()

            // Placeholder derecho
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
                    // Frase en curso
                    if engine.isListening && !engine.currentOriginal.isEmpty {
                        LiveBubble(
                            original:   engine.currentOriginal,
                            translated: engine.currentTranslated,
                            direction:  engine.direction
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
            Text("Selecciona la dirección y pulsa el micrófono")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {

            // Estado
            if engine.isListening || engine.isSpeaking {
                Text(engine.isSpeaking ? "Traduciendo..." : "Escuchando...")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if let err = engine.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }

            // Micrófono
            Button {
                if engine.isListening { engine.stopListening() }
                else { try? engine.startListening() }
            } label: {
                ZStack {
                    Circle()
                        .fill(engine.isListening ? Color.red.opacity(0.18) : Color.white.opacity(0.1))
                        .frame(width: 76, height: 76)
                    Image(systemName: engine.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(engine.isListening ? .red : .white)
                }
            }
            .disabled(!engine.isSessionReady)
            .opacity(engine.isSessionReady ? 1 : 0.35)
            .buttonStyle(.plain)
            .scaleEffect(engine.isListening ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: engine.isListening)

            if !engine.isSessionReady {
                Text("Descargando modelos...").font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1))
    }
}

// MARK: - BubbleView

struct BubbleView: View {
    let message: TranslationMessage

    var isLeft: Bool  { message.direction == .enToEs }
    var color: Color  { isLeft ? .blue : .green }
    var sourceFlag: String { isLeft ? "🇺🇸" : "🇪🇸" }
    var targetFlag: String { isLeft ? "🇪🇸" : "🇺🇸" }

    var body: some View {
        VStack(alignment: isLeft ? .leading : .trailing, spacing: 4) {
            // Timestamp
            HStack {
                if !isLeft { Spacer() }
                Text(sourceFlag + " " + message.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.caption2).foregroundStyle(.white.opacity(0.28))
                if isLeft { Spacer() }
            }
            HStack(alignment: .top) {
                if !isLeft { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.original)
                        .font(.body)
                        .foregroundStyle(.white)
                    HStack(spacing: 4) {
                        Text(targetFlag).font(.caption)
                        Text(message.translated)
                            .font(.body.italic())
                            .foregroundStyle(color.opacity(0.9))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.3), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                if isLeft { Spacer(minLength: 40) }
            }
        }
    }
}

// MARK: - LiveBubble

struct LiveBubble: View {
    let original:   String
    let translated: String
    let direction:  TranslationDirection

    var isLeft: Bool  { direction == .enToEs }
    var color: Color  { isLeft ? .blue : .green }

    var body: some View {
        HStack {
            if !isLeft { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(original)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.5))
                if !translated.isEmpty {
                    Text(translated)
                        .font(.body.italic())
                        .foregroundStyle(color.opacity(0.6))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.15), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if isLeft { Spacer(minLength: 40) }
        }
    }
}

// MARK: - HistoryView

struct HistoryView: View {
    let store: ConversationStore
    @State private var selected: StoredConversation?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                if store.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 48)).foregroundStyle(.white.opacity(0.12))
                        Text("Sin conversaciones guardadas")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.3))
                    }
                } else {
                    List {
                        ForEach(store.conversations) { conv in
                            Button { selected = conv } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conv.title)
                                        .font(.subheadline.bold()).foregroundStyle(.white)
                                    Text(conv.preview)
                                        .font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                    Text("\(conv.messages.count) mensajes")
                                        .font(.caption2).foregroundStyle(.white.opacity(0.25))
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
            .sheet(item: $selected) { ConversationDetailView(conversation: $0) }
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
    var isLeft: Bool  { message.sourceLang == "en" }
    var color: Color  { isLeft ? .blue : .green }

    var body: some View {
        VStack(alignment: isLeft ? .leading : .trailing, spacing: 4) {
            HStack {
                if !isLeft { Spacer() }
                Text((isLeft ? "🇺🇸 " : "🇪🇸 ") + message.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.caption2).foregroundStyle(.white.opacity(0.28))
                if isLeft { Spacer() }
            }
            HStack {
                if !isLeft { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.original).font(.body).foregroundStyle(.white)
                    Text(message.translated).font(.body.italic()).foregroundStyle(color.opacity(0.9))
                }
                .padding(14)
                .background(color.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.3), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                if isLeft { Spacer(minLength: 40) }
            }
        }
    }
}

#Preview { ContentView() }
