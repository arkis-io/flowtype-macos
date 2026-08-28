import Foundation

final class TranscriptionService {
    private let processRunner: ProcessRunner
    private let bundle: Bundle

    init(processRunner: ProcessRunner = ProcessRunner(), bundle: Bundle = .main) {
        self.processRunner = processRunner
        self.bundle = bundle
    }

    func transcribe(
        audioURL: URL,
        config: TranscriptionConfig,
        environment: [String: String],
        dictionary: PersonalDictionary
    ) async throws -> String {
        switch config.provider.lowercased() {
        case "local":
            return try await transcribeLocally(audioURL: audioURL, config: config, dictionary: dictionary)
        case "openai":
            guard let key = nonEmpty(environment["OPENAI_API_KEY"]) else {
                throw FlowTypeError.configuration("transcription.provider is openai, but OPENAI_API_KEY is missing from .env.")
            }
            return try await transcribeWithAPI(
                audioURL: audioURL,
                endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                apiKey: key,
                model: config.openAIModel,
                language: config.language,
                prompt: dictionary.recognitionPrompt
            )
        case "groq":
            guard let key = nonEmpty(environment["GROQ_API_KEY"]) else {
                throw FlowTypeError.configuration("transcription.provider is groq, but GROQ_API_KEY is missing from .env.")
            }
            return try await transcribeWithAPI(
                audioURL: audioURL,
                endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
                apiKey: key,
                model: config.groqModel,
                language: config.language,
                prompt: dictionary.recognitionPrompt
            )
        default:
            throw FlowTypeError.configuration("Unknown transcription provider '\(config.provider)'. Use local, openai, or groq.")
        }
    }

    private func transcribeLocally(
        audioURL: URL,
        config: TranscriptionConfig,
        dictionary: PersonalDictionary
    ) async throws -> String {
        let executablePath = resolveWhisperExecutable(config.localExecutable)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw FlowTypeError.configuration(
                "FlowType's offline transcription engine is missing. Reinstall FlowType, or choose a custom whisper-cli in Settings → Transcription."
            )
        }

        let modelPath = config.localModelPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw FlowTypeError.configuration(
                "The offline Whisper model was not found. Open FlowType Settings and select Install Offline Model."
            )
        }

        let outputBase = audioURL.deletingPathExtension().appendingPathExtension("transcript")
        var arguments = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", config.language,
            "-otxt",
            "-of", outputBase.path,
            "-nt",
            "-np"
        ]
        if let prompt = dictionary.recognitionPrompt {
            arguments.append(contentsOf: ["--prompt", String(prompt.prefix(1_000))])
        }

        let result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments
        )
        try Task.checkCancellation()

        let outputURL = URL(fileURLWithPath: outputBase.path + ".txt")
        guard result.terminationStatus == 0,
              let text = try? String(contentsOf: outputURL, encoding: .utf8) else {
            throw FlowTypeError.transcription(
                "Local transcription failed: \(whisperFailureDetails(from: result))"
            )
        }
        return try normalizedTranscript(text)
    }

    private func transcribeWithAPI(
        audioURL: URL,
        endpoint: URL,
        apiKey: String,
        model: String,
        language: String,
        prompt: String?
    ) async throws -> String {
        let boundary = "FlowType-\(UUID().uuidString)"
        var body = MultipartFormData(boundary: boundary)
        body.addField(name: "model", value: model)
        body.addField(name: "language", value: language)
        body.addField(name: "response_format", value: "json")
        if let prompt {
            body.addField(name: "prompt", value: prompt)
        }
        body.addFile(
            name: "file",
            filename: "recording.wav",
            mimeType: "audio/wav",
            data: try Data(contentsOf: audioURL)
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finalizedData()

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? "No response body"
            throw FlowTypeError.transcription("Cloud transcription failed: \(String(details.prefix(500)))")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw FlowTypeError.transcription("The transcription provider returned a response without a text field.")
        }
        return try normalizedTranscript(text)
    }

    func resolveWhisperExecutable(_ configuredPath: String) -> String {
        let normalized = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = normalized.expandingTildeInPath
        if normalized.lowercased() != "bundled",
           FileManager.default.isExecutableFile(atPath: expanded) {
            return expanded
        }

        let bundled = bundle.resourceURL?
            .appendingPathComponent("Whisper/bin/whisper-cli")
            .path ?? ""
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for candidate in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return normalized.lowercased() == "bundled" ? bundled : expanded
    }

    private func normalizedTranscript(_ text: String) throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw FlowTypeError.transcription("No speech was detected in the recording.")
        }
        return normalized
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func whisperFailureDetails(from result: ProcessResult) -> String {
        let data = result.standardError.isEmpty ? result.standardOutput : result.standardError
        guard let raw = String(data: data, encoding: .utf8) else {
            return "whisper.cpp returned exit status \(result.terminationStatus)."
        }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let actionable = lines.filter { line in
            let lowercased = line.lowercased()
            return lowercased.contains("error:") || lowercased.contains("failed")
        }
        let selected = actionable.isEmpty ? Array(lines.suffix(3)) : Array(actionable.suffix(3))
        return selected.isEmpty
            ? "whisper.cpp returned exit status \(result.terminationStatus)."
            : selected.joined(separator: " ")
    }
}

private struct MultipartFormData {
    let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data fileData: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        append("\r\n")
    }

    mutating func finalizedData() -> Data {
        append("--\(boundary)--\r\n")
        return data
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }
}
