import Translation
import Observation

@Observable
@MainActor
final class AppleTranslator {

    var config: TranslationSession.Configuration?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingText = ""

    func translate(_ text: String, from: String, to: String) async throws -> String {
        pendingText = text
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: from),
                target: Locale.Language(identifier: to)
            )
        }
    }

    func handleSession(_ session: TranslationSession) async {
        guard let cont = continuation else { return }
        continuation = nil
        do {
            let response = try await session.translate(pendingText)
            cont.resume(returning: response.targetText)
        } catch {
            cont.resume(throwing: error)
        }
        config = nil
    }
}
