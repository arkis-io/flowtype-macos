import Foundation

final class ConfigStore {
    let applicationSupportURL: URL
    let configURL: URL
    let defaultDictionaryURL: URL
    let environmentURL: URL
    let outputVolumeRecoveryURL: URL

    init(fileManager: FileManager = .default) throws {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FlowType", isDirectory: true)

        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        applicationSupportURL = base
        configURL = base.appendingPathComponent("config.json")
        defaultDictionaryURL = base.appendingPathComponent("dictionary.txt")
        environmentURL = base.appendingPathComponent(".env")
        outputVolumeRecoveryURL = base.appendingPathComponent("output-volume-recovery.json")

        try createDefaultsIfNeeded(fileManager: fileManager)
    }

    func load() throws -> AppConfig {
        let defaultsData = try JSONEncoder.flowType.encode(AppConfig.defaultConfig)
        let defaultsObject = try jsonDictionary(from: defaultsData)
        let userData = try Data(contentsOf: configURL)
        let userObject = try jsonDictionary(from: userData)
        let merged = merge(defaults: defaultsObject, overrides: userObject)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)

        do {
            return try JSONDecoder().decode(AppConfig.self, from: mergedData)
        } catch {
            throw FlowTypeError.configuration("Could not read config.json: \(error.localizedDescription)")
        }
    }

    func save(_ config: AppConfig) throws {
        try SettingsValidator.validate(config)
        let data = try JSONEncoder.flowType.encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    func loadDictionary(for config: AppConfig) -> String {
        let path = config.dictionaryPath.expandingTildeInPath
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func save(_ config: AppConfig, dictionaryContents: String) throws {
        try SettingsValidator.validate(config)

        let dictionaryURL = URL(fileURLWithPath: config.dictionaryPath.expandingTildeInPath)
        let fileManager = FileManager.default
        let previousConfig = try? Data(contentsOf: configURL)
        let previousDictionary = try? Data(contentsOf: dictionaryURL)

        do {
            try fileManager.createDirectory(
                at: dictionaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder.flowType.encode(config).write(to: configURL, options: .atomic)
            try Data(dictionaryContents.utf8).write(to: dictionaryURL, options: .atomic)
        } catch {
            if let previousConfig {
                try? previousConfig.write(to: configURL, options: .atomic)
            }
            if let previousDictionary {
                try? previousDictionary.write(to: dictionaryURL, options: .atomic)
            }
            throw error
        }
    }

    func loadEnvironment() -> [String: String] {
        var values: [String: String] = [:]
        let fileManager = FileManager.default
        let candidateURLs = [
            environmentURL,
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/FlowType/.env"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(".env")
        ]

        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in contents.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                    continue
                }

                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
                    value.removeFirst()
                    value.removeLast()
                }
                if !key.isEmpty {
                    values[key] = value
                }
            }
        }

        for (key, value) in ProcessInfo.processInfo.environment {
            values[key] = value
        }
        return values
    }

    private func createDefaultsIfNeeded(fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: configURL.path) {
            try JSONEncoder.flowType.encode(AppConfig.defaultConfig).write(to: configURL, options: .atomic)
        }

        if !fileManager.fileExists(atPath: defaultDictionaryURL.path) {
            let dictionary = """
            # One vocabulary hint per line:
            FlowType
            Arkis

            # Or a case-insensitive exact replacement:
            whisper flow => Wispr Flow
            super whisper => Superwhisper
            """
            try dictionary.write(to: defaultDictionaryURL, atomically: true, encoding: .utf8)
        }

        if !fileManager.fileExists(atPath: environmentURL.path) {
            let environment = """
            # Add only the keys for the providers you choose in config.json.
            # OPENAI_API_KEY=
            # GROQ_API_KEY=
            # LLM_API_KEY=
            # LLM_BASE_URL=https://api.openai.com/v1
            # LLM_MODEL=gpt-5-mini
            """
            try environment.write(to: environmentURL, atomically: true, encoding: .utf8)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
    }

    private func jsonDictionary(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowTypeError.configuration("config.json must contain a JSON object.")
        }
        return object
    }

    private func merge(defaults: [String: Any], overrides: [String: Any]) -> [String: Any] {
        var result = defaults
        for (key, overrideValue) in overrides {
            if let defaultObject = defaults[key] as? [String: Any],
               let overrideObject = overrideValue as? [String: Any] {
                result[key] = merge(defaults: defaultObject, overrides: overrideObject)
            } else {
                result[key] = overrideValue
            }
        }
        return result
    }
}

private extension JSONEncoder {
    static var flowType: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
