import Foundation

struct PersonalDictionary: Equatable {
    struct Replacement: Equatable {
        let source: String
        let destination: String
    }

    let vocabulary: [String]
    let replacements: [Replacement]

    static let empty = PersonalDictionary(vocabulary: [], replacements: [])

    static func load(from path: String) -> PersonalDictionary {
        guard let contents = try? String(contentsOfFile: path.expandingTildeInPath, encoding: .utf8) else {
            return .empty
        }
        return parse(contents)
    }

    static func parse(_ contents: String) -> PersonalDictionary {
        var vocabulary: [String] = []
        var replacements: [Replacement] = []

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let range = line.range(of: "=>") {
                let source = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let destination = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !source.isEmpty, !destination.isEmpty {
                    replacements.append(Replacement(source: source, destination: destination))
                    vocabulary.append(destination)
                }
            } else {
                vocabulary.append(line)
            }
        }

        return PersonalDictionary(
            vocabulary: stableUnique(vocabulary),
            replacements: replacements
        )
    }

    var recognitionPrompt: String? {
        guard !vocabulary.isEmpty else { return nil }
        return "Vocabulary: " + vocabulary.joined(separator: ", ")
    }

    func applyingReplacements(to text: String) -> String {
        replacements.reduce(text) { result, replacement in
            let escaped = NSRegularExpression.escapedPattern(for: replacement.source)
            guard let expression = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                options: [.caseInsensitive]
            ) else {
                return result
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.destination)
            )
        }
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            return seen.insert(key).inserted
        }
    }
}
