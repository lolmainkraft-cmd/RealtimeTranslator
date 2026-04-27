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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { [weak self] cont in
                guard let self else { cont.resume(throwing: CancellationError()); return }
                // Cancelar cualquier traducción pendiente anterior
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = cont
                self.config = TranslationSession.Configuration(
                    source: Locale.Language(identifier: from),
                    target: Locale.Language(identifier: to)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
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

    func cancel() {
        guard let cont = continuation else { return }
        continuation = nil
        config = nil
        cont.resume(throwing: CancellationError())
    }
}
