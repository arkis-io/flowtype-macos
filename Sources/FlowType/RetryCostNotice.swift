import Foundation

/// Explains which paid providers a retry would contact again, so the user can
/// see the cost boundary before FlowType re-sends retained audio or text.
/// Local transcription and a local cleanup endpoint produce no notice.
enum RetryCostNotice {
    struct Summary: Equatable {
        /// Provider display names in pipeline order, each listed once.
        let providers: [String]
        /// Full sentence for a confirmation dialog or tooltip.
        let message: String
    }

    static func summary(for config: AppConfig) -> Summary? {
        var providers: [String] = []
        var actions: [String] = []

        let transcription = config.transcription.provider.lowercased()
        if transcription != "local" {
            let name = displayName(transcription)
            providers.append(name)
            actions.append("send the retained audio to \(name) for transcription")
        }

        let cleanup = config.cleanup.provider.lowercased()
        if config.cleanup.enabled, cleanup != "local" {
            let name = displayName(cleanup)
            if !providers.contains(name) {
                providers.append(name)
            }
            actions.append("send the transcript to \(name) for cleanup")
        }

        guard !actions.isEmpty else { return nil }
        let message = "Retrying will " + actions.joined(separator: " and ")
            + " again. Your provider account may be charged for this request."
        return Summary(providers: providers, message: message)
    }

    static func displayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openai": return "OpenAI"
        case "groq": return "Groq"
        case "local": return "Local"
        default: return provider
        }
    }
}
