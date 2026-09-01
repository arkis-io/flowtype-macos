import Foundation

enum TranscriptQuality {
    static func isOnlyNonSpeechMarkers(_ text: String) -> Bool {
        let words = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return false }
        let nonSpeechWords = Set([
            "inaudible", "unintelligible", "silence", "silent", "laughing", "laughter",
            "music", "applause", "background", "noise"
        ])
        if words.allSatisfy(nonSpeechWords.contains) {
            return true
        }

        let markerWords = Set(["blank", "audio", "no", "speech", "detected"])
        return (words.contains("blank") && words.allSatisfy(markerWords.contains))
            || (words.contains("speech") && words.allSatisfy(markerWords.contains))
    }
}
