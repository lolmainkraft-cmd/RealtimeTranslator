import Foundation

// MARK: - Azure Translator REST API

struct AzureTranslatorClient {

    private let key      = "8kwvgmcxzuMA1cc9eLq58R2VaQwJ4yQFrqxhzorlx1EzQMzmkJO9JQQJ88BDACULnChXJ1v1AAAwACOGbnvm"
    private let endpoint = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0"

    func translate(_ text: String, from: String, to: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard let url = URL(string: "\(endpoint)&from=\(from)&to=\(to)") else { return text }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([["Text": trimmed]])
        req.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: req)

        struct Result: Decodable {
            struct Translation: Decodable { let text: String }
            let translations: [Translation]
        }
        guard let results = try? JSONDecoder().decode([Result].self, from: data),
              let translated = results.first?.translations.first?.text
        else { return text }

        return translated
    }
}
