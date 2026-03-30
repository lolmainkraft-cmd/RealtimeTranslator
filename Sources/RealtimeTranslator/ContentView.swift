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
            Color(white: 0.06).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                panels
                bottomBar
            }
        }
        .sheet(isPresented: $showHistory) { HistoryView(store: engine.store) }
        .translationTask(configENtoES) { engine.setSessionENtoES($0) }
        .translationTask(configEStoEN) { engine.setSessionEStoEN($0) }
        .task { _ = await engine.requestPermissions() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 40, height: 40)
            }

            Spacer()

            HStack(spacing: 8) {
                LangButton(title: "INGLÉS",   flag: "🇺🇸",
                           isSelected: engine.direction == .enToEs, color: .blue)
                { engine.setDirection(.enToEs) }

                LangButton(title: "ESPAÑOL",  flag: "🇪🇸",
                           isSelected: engine.direction == .esToEn, color: .green)
                { engine.setDirection(.esToEn) }
            }
            .disabled(!engine.isSessionReady)

            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.11))
    }

    // MARK: - Dos paneles

    private var panels: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Panel inglés (arriba)
                TranslationPanel(
                    flag:      "🇺🇸",
                    langLabel: "INGLÉS",
                    messages:  engine.messages.map { ($0.english, $0.id) },
                    liveText:  engine.liveEnglish,
                    isInput:   engine.direction == .enToEs && engine.isListening,
                    isOutput:  engine.direction == .esToEn && engine.isSpeaking,
                    audioLevel: engine.direction == .enToEs ? engine.audioLevel : 0,
                    color:     .blue,
                    height:    geo.size.height / 2
                )

                Divider().background(Color.white.opacity(0.08))

                // Panel español (abajo)
                TranslationPanel(
                    flag:      "🇪🇸",
                    langLabel: "ESPAÑOL",
                    messages:  engine.messages.map { ($0.spanish, $0.id) },
                    liveText:  engine.liveSpanish,
                    isInput:   engine.direction == .esToEn && engine.isListening,
                    isOutput:  engine.direction == .enToEs && engine.isSpeaking,
                    audioLevel: engine.direction == .esToEn ? engine.audioLevel : 0,
                    color:     .green,
                    height:    geo.size.height / 2
                )
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let err = engine.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            Button {
                if engine.isListening { engine.stopListening() }
                else { try? engine.startListening() }
            } label: {
                ZStack {
                    Circle()
                        .fill(engine.isListening ? Color.red.opacity(0.2) : Color.white.opacity(0.1))
                        .frame(width: 72, height: 72)
                    Image(systemName: engine.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(engine.isListening ? .red : .white)
                }
            }
            .disabled(!engine.isSessionReady)
            .opacity(engine.isSessionReady ? 1 : 0.35)
            .buttonStyle(.plain)
            .scaleEffect(engine.isListening && !engine.isSpeaking ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: engine.isListening)

            if !engine.isSessionReady {
                Text("Descargando modelos...").font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.11))
    }
}

// MARK: - TranslationPanel

struct TranslationPanel: View {
    let flag:       String
    let langLabel:  String
    let messages:   [(text: String, id: UUID)]
    let liveText:   String
    let isInput:    Bool     // escuchando en este idioma
    let isOutput:   Bool     // reproduciendo en este idioma
    let audioLevel: Float
    let color:      Color
    let height:     CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Cabecera del panel
            HStack(spacing: 8) {
                Text(flag).font(.title3)
                Text(langLabel)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Spacer()
                if isInput {
                    WaveformView(level: audioLevel, color: color)
                        .frame(width: 48, height: 18)
                }
                if isOutput {
                    Label("", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(color.opacity(0.7))
                        .symbolEffect(.variableColor, isActive: isOutput)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.06))

            // Contenido
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages, id: \.id) { item in
                            Text(item.text)
                                .font(.body)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(item.id)
                        }
                        // Texto en vivo (parcial)
                        if !liveText.isEmpty {
                            Text(liveText)
                                .font(.body)
                                .foregroundStyle(color.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("live")
                        }
                        if messages.isEmpty && liveText.isEmpty {
                            Text("—")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.15))
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: liveText) {
                    withAnimation { proxy.scrollTo("live", anchor: .bottom) }
                }
            }
        }
        .frame(height: height)
        .background(Color(white: 0.07))
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let level: Float
    let color: Color

    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let delay = Double(i) * 0.08
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4, height: barHeight(for: i))
                    .animation(.easeInOut(duration: 0.15).delay(delay), value: level)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 3
        let max:  CGFloat = 18
        // Centro más alto, extremos más bajos
        let shape: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
        let h = base + CGFloat(level * shape[index]) * (max - base)
        return max(base, h)
    }
}

// MARK: - LangButton

struct LangButton: View {
    let title:      String
    let flag:       String
    let isSelected: Bool
    let color:      Color
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(flag).font(.title3)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? color : .white.opacity(0.35))
            }
            .frame(width: 84, height: 56)
            .background(isSelected ? color.opacity(0.18) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color.opacity(0.55) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - History

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
                        Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.white.opacity(0.12))
                        Text("Sin conversaciones guardadas").font(.subheadline).foregroundStyle(.white.opacity(0.3))
                    }
                } else {
                    List {
                        ForEach(store.conversations) { conv in
                            Button { selected = conv } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conv.title).font(.subheadline.bold()).foregroundStyle(.white)
                                    Text(conv.preview).font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                    Text("\(conv.messages.count) frases").font(.caption2).foregroundStyle(.white.opacity(0.25))
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color(white: 0.12))
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Historial").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() }.foregroundStyle(.white) } }
            .sheet(item: $selected) { ConversationDetailView(conversation: $0) }
        }
    }
}

struct ConversationDetailView: View {
    let conversation: StoredConversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.07).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(conversation.messages) { msg in
                            HStack(spacing: 12) {
                                Text(msg.sourceLang == "en" ? "🇺🇸" : "🇪🇸")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(msg.original).font(.subheadline).foregroundStyle(.white)
                                    Text(msg.translated).font(.subheadline.italic())
                                        .foregroundStyle(msg.sourceLang == "en" ? Color.blue.opacity(0.8) : Color.green.opacity(0.8))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            Divider().background(.white.opacity(0.06)).padding(.leading, 16)
                        }
                    }
                }
            }
            .navigationTitle(conversation.title).navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() }.foregroundStyle(.white) } }
        }
    }
}

#Preview { ContentView() }
