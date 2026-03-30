import Foundation
import Observation

// MARK: - Data models

struct StoredConversation: Codable, Identifiable {
    var id      = UUID()
    var date    = Date()
    var messages: [StoredMessage] = []

    var isEmpty: Bool { messages.isEmpty }

    var title: String {
        date.formatted(.dateTime.day().month(.wide).hour().minute())
    }

    var preview: String {
        messages.first.map { "\($0.sourceLang == "en" ? "🇺🇸" : "🇪🇸") \($0.original)" } ?? ""
    }
}

struct StoredMessage: Codable, Identifiable {
    var id        = UUID()
    var original:   String
    var translated: String
    var sourceLang: String   // "en" | "es"
    var timestamp   = Date()
}

// MARK: - Store

@Observable
final class ConversationStore {

    var conversations: [StoredConversation] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rt_conversations.json")
    }()

    init() { load() }

    func upsert(_ conversation: StoredConversation) {
        guard !conversation.isEmpty else { return }
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([StoredConversation].self, from: data)) ?? []
    }

    private func persist() {
        try? JSONEncoder().encode(conversations).write(to: fileURL, options: .atomic)
    }
}
