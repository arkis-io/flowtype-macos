import CryptoKit
import Foundation

struct LocalModelSpecification: Equatable {
    let identifier: String
    let displayName: String
    let downloadSizeLabel: String
    let filename: String
    let downloadURL: URL
    let expectedByteCount: Int64
    let expectedSHA256: String

    init(
        identifier: String = "custom",
        displayName: String = "Custom model",
        downloadSizeLabel: String = "",
        filename: String,
        downloadURL: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.downloadSizeLabel = downloadSizeLabel
        self.filename = filename
        self.downloadURL = downloadURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
    }

    static let smallEnglish = LocalModelSpecification(
        identifier: "small_en",
        displayName: "Fast — Small English",
        downloadSizeLabel: "488 MB",
        filename: "ggml-small.en.bin",
        downloadURL: URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/c521a4b02f422512d734391fdf08bb08c0862f68/ggml-small.en.bin"
        )!,
        expectedByteCount: 487_614_201,
        expectedSHA256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
    )

    static let mediumEnglish = LocalModelSpecification(
        identifier: "medium_en",
        displayName: "Recommended — Medium English",
        downloadSizeLabel: "1.53 GB",
        filename: "ggml-medium.en.bin",
        downloadURL: URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/c521a4b02f422512d734391fdf08bb08c0862f68/ggml-medium.en.bin"
        )!,
        expectedByteCount: 1_533_774_781,
        expectedSHA256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"
    )

    static let supported: [LocalModelSpecification] = [.mediumEnglish, .smallEnglish]

    static func matching(path: String) -> LocalModelSpecification? {
        let filename = URL(fileURLWithPath: path.expandingTildeInPath).lastPathComponent
        return supported.first { $0.filename == filename }
    }
}

enum LocalModelState: Equatable {
    case notInstalled
    case downloading(Double)
    case verifying
    case ready
    case failed(String)
}

enum LocalModelFileError: LocalizedError {
    case unexpectedSize(expected: Int64, actual: Int64)
    case checksumMismatch
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .unexpectedSize(let expected, let actual):
            return "The model download had the wrong size (expected \(expected) bytes, received \(actual))."
        case .checksumMismatch:
            return "The model download failed its security check. Nothing was installed."
        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Not enough free disk space. FlowType needs \(formatter.string(fromByteCount: required)); \(formatter.string(fromByteCount: available)) is available."
        case .invalidServerResponse:
            return "The model server did not return a valid download."
        }
    }
}

enum LocalModelFileVerifier {
    static func verify(_ fileURL: URL, specification: LocalModelSpecification) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == specification.expectedByteCount else {
            throw LocalModelFileError.unexpectedSize(
                expected: specification.expectedByteCount,
                actual: byteCount
            )
        }

        let digest = try sha256(of: fileURL)
        guard digest.caseInsensitiveCompare(specification.expectedSHA256) == .orderedSame else {
            throw LocalModelFileError.checksumMismatch
        }
    }

    static func installVerifiedFile(
        stagingURL: URL,
        destinationURL: URL,
        specification: LocalModelSpecification
    ) throws {
        try verify(stagingURL, specification: specification)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class LocalModelManager {
    private(set) var specification: LocalModelSpecification

    var modelURL: URL {
        modelsDirectoryURL.appendingPathComponent(specification.filename)
    }

    var onStateChange: ((LocalModelState) -> Void)?
    private(set) var state: LocalModelState = .notInstalled {
        didSet { onStateChange?(state) }
    }

    private let modelsDirectoryURL: URL
    private let session: URLSession
    private var downloadTask: URLSessionDownloadTask?
    private var progressTimer: Timer?
    private var operationID = UUID()
    private var activeStagingURL: URL?

    init(
        applicationSupportURL: URL,
        specification: LocalModelSpecification = .mediumEnglish,
        session: URLSession = .shared
    ) {
        self.specification = specification
        self.session = session
        modelsDirectoryURL = applicationSupportURL.appendingPathComponent("models", isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    func select(_ specification: LocalModelSpecification) {
        guard self.specification != specification else { return }
        operationID = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        stopProgressTimer()
        if let activeStagingURL {
            try? FileManager.default.removeItem(at: activeStagingURL)
        }
        activeStagingURL = nil
        self.specification = specification
        refresh()
    }

    func refresh() {
        guard downloadTask == nil else { return }
        guard isInstalled else {
            state = .notInstalled
            return
        }

        let validationID = UUID()
        operationID = validationID
        state = .verifying
        let modelURL = self.modelURL
        let specification = self.specification
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try LocalModelFileVerifier.verify(modelURL, specification: specification) }
            Task { @MainActor in
                guard let self, self.operationID == validationID else { return }
                switch result {
                case .success:
                    self.state = .ready
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func install() {
        guard downloadTask == nil else { return }

        do {
            try FileManager.default.createDirectory(
                at: modelsDirectoryURL,
                withIntermediateDirectories: true
            )
            removeStaleStagingFiles()
            try requireEnoughDiskSpace()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let currentOperationID = UUID()
        operationID = currentOperationID
        let stagingURL = modelsDirectoryURL.appendingPathComponent(".\(specification.filename).\(currentOperationID.uuidString).download")
        activeStagingURL = stagingURL
        try? FileManager.default.removeItem(at: stagingURL)

        let request = URLRequest(
            url: specification.downloadURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        let task = session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let temporaryURL else {
                    throw LocalModelFileError.invalidServerResponse
                }
                try? FileManager.default.removeItem(at: stagingURL)
                try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
                result = .success(stagingURL)
            } catch {
                result = .failure(error)
            }

            Task { @MainActor in
                self?.downloadDidFinish(result, operationID: currentOperationID)
            }
        }
        downloadTask = task
        state = .downloading(0)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak task] _ in
            guard let self, let task else { return }
            Task { @MainActor in
                guard self.operationID == currentOperationID else { return }
                self.state = .downloading(min(max(task.progress.fractionCompleted, 0), 1))
            }
        }
        task.resume()
    }

    func cancelDownload() {
        guard downloadTask != nil else { return }
        operationID = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        stopProgressTimer()
        if let activeStagingURL {
            try? FileManager.default.removeItem(at: activeStagingURL)
        }
        activeStagingURL = nil
        state = isInstalled ? .ready : .notInstalled
    }

    func removeInstalledModel() throws {
        operationID = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        stopProgressTimer()
        if let activeStagingURL {
            try? FileManager.default.removeItem(at: activeStagingURL)
        }
        activeStagingURL = nil
        if isInstalled {
            try FileManager.default.removeItem(at: modelURL)
        }
        state = .notInstalled
    }

    private func downloadDidFinish(_ result: Result<URL, Error>, operationID completedOperationID: UUID) {
        guard operationID == completedOperationID else {
            if case .success(let stagingURL) = result {
                try? FileManager.default.removeItem(at: stagingURL)
            }
            return
        }

        downloadTask = nil
        stopProgressTimer()

        switch result {
        case .failure(let error):
            activeStagingURL = nil
            if (error as? URLError)?.code == .cancelled {
                state = isInstalled ? .ready : .notInstalled
            } else {
                state = .failed(error.localizedDescription)
            }
        case .success(let stagingURL):
            state = .verifying
            let destinationURL = modelURL
            let specification = self.specification
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let installResult = Result {
                    try LocalModelFileVerifier.installVerifiedFile(
                        stagingURL: stagingURL,
                        destinationURL: destinationURL,
                        specification: specification
                    )
                }
                Task { @MainActor in
                    guard let self, self.operationID == completedOperationID else {
                        try? FileManager.default.removeItem(at: stagingURL)
                        return
                    }
                    self.activeStagingURL = nil
                    switch installResult {
                    case .success:
                        self.state = .ready
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: stagingURL)
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func requireEnoughDiskSpace() throws {
        let values = try modelsDirectoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let required = specification.expectedByteCount + 150_000_000
        guard available >= required else {
            throw LocalModelFileError.insufficientDiskSpace(required: required, available: available)
        }
    }

    private func removeStaleStagingFiles() {
        let prefix = ".\(specification.filename)."
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for child in children
        where child.lastPathComponent.hasPrefix(prefix)
            && child.lastPathComponent.hasSuffix(".download")
            && child != activeStagingURL {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
