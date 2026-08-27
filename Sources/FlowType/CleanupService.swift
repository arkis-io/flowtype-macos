import Foundation

final class CleanupService {
    func clean(
        transcript: String,
        config: CleanupConfig,
        environment: [String: String],
        dictionary: PersonalDictionary
    ) async throws -> String {
        guard config.enabled else { return transcript }

        let apiKey = resolveAPIKey(config: config, environment: environment)
        let isLocalProvider = config.provider.lowercased() == "local"
        guard apiKey != nil || isLocalProvider else {
            if config.fallbackToRawOnError {
                return transcript
            }
            throw FlowTypeError.configuration("Cleanup is enabled, but no LLM_API_KEY or provider API key exists in .env.")
        }

        let baseURLString = environment["LLM_BASE_URL"] ?? config.baseURL
        let model = environment["LLM_MODEL"] ?? config.model
        guard let baseURL = URL(string: baseURLString) else {
            throw FlowTypeError.configuration("cleanup.baseURL is not a valid URL.")
        }
        let endpoint = baseURL.appendingPathComponent("chat/completions")

        let vocabularyInstruction: String
        if dictionary.vocabulary.isEmpty {
            vocabularyInstruction = ""
        } else {
            vocabularyInstruction = "\nPreferred spellings: \(dictionary.vocabulary.joined(separator: ", "))."
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": config.prompt + vocabularyInstruction],
                ["role": "user", "content": transcript]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let details = String(data: data, encoding: .utf8) ?? "No response body"
                throw FlowTypeError.cleanup("LLM cleanup failed: \(String(details.prefix(500)))")
            }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw FlowTypeError.cleanup("The LLM returned a response without cleaned text.")
            }

            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? transcript : cleaned
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if config.fallbackToRawOnError {
                return transcript
            }
            throw error
        }
    }

    private func resolveAPIKey(config: CleanupConfig, environment: [String: String]) -> String? {
        let candidates: [String?]
        switch config.provider.lowercased() {
        case "groq":
            candidates = [environment["LLM_API_KEY"], environment["GROQ_API_KEY"]]
        case "openai":
            candidates = [environment["LLM_API_KEY"], environment["OPENAI_API_KEY"]]
        default:
            candidates = [environment["LLM_API_KEY"]]
        }
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
