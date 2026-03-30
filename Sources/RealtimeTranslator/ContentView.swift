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
                micBar
            }
        }
        .sheet(isPresented: $showHistory) { HistoryView(store: engine.store) }
        .translationTask(configENtoES) { engine.setSessionENtoES($0) }
        .translationTask(configEStoEN) { engine.setSessionEStoEN($0) }
        .task { _ = await engine.requestPermissions() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Traductor")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.11))
    }

    // MARK: - Paneles

    private var panels: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Panel inglés (arriba)
                LangPanel(
                    flag:       "🇺🇸",
                    label:      "INGLÉS",
                    messages:   engine.messages.map { $0.english },
                    liveText:   engine.liveEnglish,
                    isListening: engine.activeMic == .english,
                    isSpeaking:  engine.activeMic == .spanish && engine.isSpeaking,
                    audioLevel:  engine.activeMic == .english ? engine.audioLevel : 0,
                    color:      .blue,
                    height:     geo.size.height / 2
                )

                Divider().background(Color.white.opacity(0.08))

                // Panel español (abajo)
                LangPanel(
                    flag:       "🇪🇸",
                    label:      "ESPAÑOL",
                    messages:   engine.messages.map { $0.spanish },
                    liveText:   engine.liveSpanish,
                    isListening: engine.activeMic == .spanish,
                    isSpeaking:  engine.activeMic == .english && engine.isSpeaking,
                    audioLevel:  engine.activeMic == .spanish ? engine.audioLevel : 0,
                    color:      .green,
                    height:     geo.size.height / 2
                )
            }
        }
    }

    // MARK: - Barra de micros

    private var micBar: some View {
        VStack(spacing: 6) {
            if let err = engine.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            if !engine.isReady {
                Text("Descargando modelos de traducción...")
                    .font(.caption2).foregroundStyle(.white.opacity(0.3))
            }

            HStack(spacing: 32) {

                // Mic inglés → traduce a español en tiempo real → AirPods
                MicButton(
                    flag:      "🇺🇸",
                    label:     "INGLÉS",
                    hint:      "🎧 AirPods",
                    isActive:  engine.activeMic == .english,
                    color:     .blue,
                    audioLevel: engine.activeMic == .english ? engine.audioLevel : 0
                ) { engine.tapEnglishMic() }

                // Mic español → traduce a inglés al terminar → altavoz
                MicButton(
                    flag:      "🇪🇸",
                    label:     "ESPAÑOL",
                    hint:      "🔊 Altavoz",
                    isActive:  engine.activeMic == .spanish,
                    color:     .green,
                    audioLevel: engine.activeMic == .spanish ? engine.audioLevel : 0
                ) { engine.tapSpanishMic() }
            }
            .disabled(!engine.isReady)
            .opacity(engine.isReady ? 1 : 0.35)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.11))
    }
}

// MARK: - LangPanel

struct LangPanel: View {
    let flag:        String
    let label:       String
    let messages:    [String]
    let liveText:    String
    let isListening: Bool
    let isSpeaking:  Bool
    let audioLevel:  Float
    let color:       Color
    let height:      CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Cabecera del panel
            HStack(spacing: 8) {
                Text(flag).font(.title3)
                Text(label).font(.caption.bold()).foregroundStyle(color)
                Spacer()
                if isListening {
                    WaveformView(level: audioLevel, color: color)
                        .frame(width: 44, height: 16)
                }
                if isSpeaking {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(color.opacity(0.7))
                        .symbolEffect(.variableColor.iterative, isActive: isSpeaking)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.07))

            // Texto
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { i, text in
                            Text(text)
                                .font(.body)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        if !liveText.isEmpty {
                            Text(liveText)
                                .font(.body)
                                .foregroundStyle(color.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("live")
                        }
                        if messages.isEmpty && liveText.isEmpty {
                            Text("—").font(.body).foregroundStyle(.white.opacity(0.12))
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                }
                .onChange(of: liveText) {
                    withAnimation { proxy.scrollTo("live", anchor: .bottom) }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - MicButton

struct MicButton: View {
    let flag:       String
    let label:      String
    let hint:       String
    let isActive:   Bool
    let color:      Color
    let audioLevel: Float
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    // Anillo exterior pulsante cuando activo
                    if isActive {
                        Circle()
                            .stroke(color.opacity(0.3), lineWidth: 3)
                            .frame(width: 82, height: 82)
                            .scaleEffect(1.0 + CGFloat(audioLevel) * 0.18)
                            .animation(.easeOut(duration: 0.1), value: audioLevel)
                    }

                    Circle()
                        .fill(isActive ? color.opacity(0.25) : Color.white.opacity(0.08))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Circle().stroke(
                                isActive ? color.opacity(0.7) : Color.white.opacity(0.15),
                                lineWidth: isActive ? 2 : 1
                            )
                        )

                    VStack(spacing: 2) {
                        Text(flag).font(.title2)
                        Image(systemName: isActive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isActive ? color : .white.opacity(0.6))
                    }
                }

                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? color : .white.opacity(0.4))

                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let level: Float
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let shapes: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
                let h = 3 + CGFloat(level * shapes[i]) * 13
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4, height: Swift.max(3, h))
                    .animation(.easeInOut(duration: 0.12).delay(Double(i) * 0.04), value: level)
            }
        }
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }.foregroundStyle(.white)
            }}
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
                            HStack(alignment: .top, spacing: 12) {
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }.foregroundStyle(.white)
            }}
        }
    }
}

#Preview { ContentView() }
