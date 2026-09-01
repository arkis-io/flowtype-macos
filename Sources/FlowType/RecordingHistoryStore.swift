import Foundation

enum RecordingStatus: String, Codable, CaseIterable {
    case captured
    case processing
    case completed
    case failed
}

enum RecordingStage: String, Codable, CaseIterable {
    case capture
    case conversion
    case transcription
    case cleanup
    case insertion
    case interrupted
}

enum RecordingAudioAvailability: String, Codable {
    case available
    case unusable
    case missing
}

struct RecordingHistoryEntry: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var durationSeconds: Double
    var status: RecordingStatus
    var stage: RecordingStage
    var firstError: String?
    var latestError: String?
    var rawTranscript: String?
    var finalTranscript: String?
    var originalProvider: String?
    var latestProvider: String?
    var attemptCount: Int
    var lastAttemptAt: Date?
    var audioAvailability: RecordingAudioAvailability

    init(id: UUID, createdAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        durationSeconds = 0
        status = .captured
        stage = .capture
        firstError = nil
        latestError = nil
        rawTranscript = nil
        finalTranscript = nil
        originalProvider = nil
        latestProvider = nil
        attemptCount = 0
        lastAttemptAt = nil
        audioAvailability = .missing
    }
}

struct RecordingCapture {
    let entryID: UUID
    let directoryURL: URL
    let audioURL: URL
}

struct RecordingHistorySnapshot {
    let entries: [RecordingHistoryEntry]
    let loadErrors: [String]
}

enum RecordingRetryEligibility: Equatable {
    case available(URL)
    case unavailable(String)
}

enum RecordingWorkKind {
    case capture
    case initialProcessing
    case retry
}

enum RecordingCancellationCause {
    case escape
    case lifecycle
}

enum RecordingCancellationDisposition: Equatable {
    case delete
    case retainInterrupted
}

struct RecordingCancellationPolicy {
    static func disposition(
        for work: RecordingWorkKind,
        cause: RecordingCancellationCause
    ) -> RecordingCancellationDisposition {
        switch (work, cause) {
        case (.capture, _), (.initialProcessing, .escape):
            return .delete
        case (.initialProcessing, .lifecycle), (.retry, _):
            return .retainInterrupted
        }
    }
}

enum RecordingHistoryStoreError: LocalizedError {
    case invalidEntry(String)
    case unavailable(String)
    case filesystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidEntry(let message), .unavailable(let message), .filesystem(let message):
            return message
        }
    }
}

final class RecordingHistoryStore {
    static let retentionInterval: TimeInterval = 3 * 24 * 60 * 60
    static let metadataFilename = "metadata.json"
    static let sourceAudioFilename = "recording.caf"
    static let canonicalAudioFilename = "recording.wav"

    let rootURL: URL
    let stagingRootURL: URL

    private let fileManager: FileManager
    private let now: () -> Date

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        stagingRootURL = rootURL.appendingPathComponent(".staging", isDirectory: true).standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        try prepareDirectory(rootURL)
        try prepareDirectory(stagingRootURL)
    }

    func beginCapture(id: UUID = UUID(), createdAt: Date? = nil) throws -> RecordingCapture {
        try prune()
        let directory = directoryURL(for: id, staging: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw RecordingHistoryStoreError.filesystem("A recording with this identifier already exists.")
        }
        try prepareDirectory(directory)
        let entry = RecordingHistoryEntry(id: id, createdAt: createdAt ?? now())
        do {
            try write(entry, in: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return RecordingCapture(
            entryID: id,
            directoryURL: directory,
            audioURL: directory.appendingPathComponent(Self.sourceAudioFilename)
        )
    }

    @discardableResult
    func promoteCapture(id: UUID, durationSeconds: Double) throws -> RecordingHistoryEntry {
        let stagingDirectory = directoryURL(for: id, staging: true)
        var entry = try readEntry(in: stagingDirectory, expectedID: id)
        guard let audioURL = validAudioURL(in: stagingDirectory) else {
            throw RecordingHistoryStoreError.unavailable(
                "The recording did not contain a readable audio file and cannot be retained."
            )
        }
        entry.durationSeconds = max(0, durationSeconds)
        entry.status = .captured
        entry.stage = .capture
        entry.audioAvailability = .available
        try write(entry, in: stagingDirectory)
        try setPrivateFilePermissions(at: audioURL)

        let visibleDirectory = directoryURL(for: id, staging: false)
        guard !fileManager.fileExists(atPath: visibleDirectory.path) else {
            throw RecordingHistoryStoreError.filesystem("The recording history entry already exists.")
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: visibleDirectory)
            try setPrivateDirectoryPermissions(at: visibleDirectory)
            try secureKnownFiles(in: visibleDirectory)
        } catch {
            throw RecordingHistoryStoreError.filesystem(
                "FlowType could not make the recording durable: \(error.localizedDescription)"
            )
        }
        return entry
    }

    func discardCapture(id: UUID) throws {
        for directory in [directoryURL(for: id, staging: true), directoryURL(for: id, staging: false)]
        where fileManager.fileExists(atPath: directory.path) {
            guard try !isSymbolicLink(directory) else {
                throw RecordingHistoryStoreError.invalidEntry("FlowType refused to remove a symlinked recording entry.")
            }
            try fileManager.removeItem(at: directory)
        }
    }

    func loadEntry(id: UUID) throws -> RecordingHistoryEntry {
        let directory = directoryURL(for: id, staging: false)
        var entry = try readEntry(in: directory, expectedID: id)
        entry.audioAvailability = derivedAudioAvailability(for: entry, in: directory)
        return entry
    }

    func listEntries(activeIDs: Set<UUID> = []) throws -> RecordingHistorySnapshot {
        try prune(activeIDs: activeIDs)
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [RecordingHistoryEntry] = []
        var errors: [String] = []

        for directory in urls {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw RecordingHistoryStoreError.invalidEntry(
                        "Ignored a symlinked recording entry named \(directory.lastPathComponent)."
                    )
                }
                guard values.isDirectory == true else { continue }
                guard let id = UUID(uuidString: directory.lastPathComponent) else {
                    throw RecordingHistoryStoreError.invalidEntry(
                        "Ignored an unrecognized recording directory named \(directory.lastPathComponent)."
                    )
                }
                var entry = try readEntry(in: directory, expectedID: id)
                entry.audioAvailability = derivedAudioAvailability(for: entry, in: directory)
                entries.append(entry)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        entries.sort {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
        return RecordingHistorySnapshot(entries: entries, loadErrors: errors)
    }

    @discardableResult
    func beginAttempt(id: UUID, provider: String, at date: Date? = nil) throws -> RecordingHistoryEntry {
        try update(id: id) { entry in
            entry.status = .processing
            entry.stage = .conversion
            entry.latestError = nil
            entry.latestProvider = provider
            if entry.originalProvider == nil {
                entry.originalProvider = provider
            }
            entry.attemptCount += 1
            entry.lastAttemptAt = date ?? now()
        }
    }

    @discardableResult
    func updateStage(id: UUID, stage: RecordingStage) throws -> RecordingHistoryEntry {
        try update(id: id) { entry in
            entry.status = .processing
            entry.stage = stage
        }
    }

    @discardableResult
    func saveRawTranscript(id: UUID, text: String) throws -> RecordingHistoryEntry {
        try update(id: id) { entry in
            entry.rawTranscript = text
        }
    }

    @discardableResult
    func completeAttempt(id: UUID, rawTranscript: String, finalTranscript: String) throws -> RecordingHistoryEntry {
        try update(id: id) { entry in
            entry.status = .completed
            entry.stage = .insertion
            entry.latestError = nil
            entry.rawTranscript = rawTranscript
            entry.finalTranscript = finalTranscript
            entry.audioAvailability = derivedAudioAvailability(
                for: entry,
                in: directoryURL(for: id, staging: false)
            )
        }
    }

    @discardableResult
    func recordInsertionFailure(id: UUID, message: String) throws -> RecordingHistoryEntry {
        try update(id: id) { entry in
            entry.status = .completed
            entry.stage = .insertion
            if entry.firstError == nil {
                entry.firstError = message
            }
            entry.latestError = message
        }
    }

    @discardableResult
    func failAttempt(
        id: UUID,
        stage: RecordingStage,
        message: String,
        unusableAudio: Bool = false
    ) throws -> RecordingHistoryEntry {
        try update(id: id) { entry in
            entry.status = .failed
            entry.stage = stage
            if entry.firstError == nil {
                entry.firstError = message
            }
            entry.latestError = message
            entry.audioAvailability = unusableAudio
                ? .unusable
                : derivedAudioAvailability(for: entry, in: directoryURL(for: id, staging: false))
        }
    }

    @discardableResult
    func markInterrupted(id: UUID, message: String = "FlowType closed before processing finished. Retry when ready.") throws -> RecordingHistoryEntry {
        try failAttempt(id: id, stage: .interrupted, message: message)
    }

    func retryEligibility(for id: UUID, activeIDs: Set<UUID> = []) throws -> RecordingRetryEligibility {
        guard !activeIDs.contains(id) else {
            return .unavailable("This recording is already being processed.")
        }
        let entry = try loadEntry(id: id)
        guard entry.createdAt.addingTimeInterval(Self.retentionInterval) > now() else {
            return .unavailable("This recording has expired.")
        }
        guard entry.status != .processing else {
            return .unavailable("This recording is already being processed.")
        }
        guard entry.audioAvailability != .unusable else {
            return .unavailable("This recording did not contain usable audio.")
        }
        guard let audioURL = validAudioURL(in: directoryURL(for: id, staging: false)) else {
            return .unavailable("The retained audio file is missing or empty.")
        }
        return .available(audioURL)
    }

    func newestRetryableEntry(activeIDs: Set<UUID> = []) throws -> RecordingHistoryEntry? {
        for entry in try listEntries(activeIDs: activeIDs).entries {
            if case .available = try retryEligibility(for: entry.id, activeIDs: activeIDs) {
                return entry
            }
        }
        return nil
    }

    func audioURL(for id: UUID) throws -> URL? {
        _ = try loadEntry(id: id)
        return validAudioURL(in: directoryURL(for: id, staging: false))
    }

    @discardableResult
    func canonicalizeAudio(id: UUID, convertedURL: URL) throws -> URL {
        let directory = directoryURL(for: id, staging: false)
        _ = try readEntry(in: directory, expectedID: id)
        guard convertedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw RecordingHistoryStoreError.invalidEntry("Converted audio was outside its recording directory.")
        }
        guard try !isSymbolicLink(convertedURL), isNonemptyRegularFile(convertedURL) else {
            throw RecordingHistoryStoreError.unavailable("The converted recording was missing or empty.")
        }

        let destination = directory.appendingPathComponent(Self.canonicalAudioFilename)
        if convertedURL.standardizedFileURL != destination.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: convertedURL, to: destination)
        }
        try setPrivateFilePermissions(at: destination)

        for filename in [Self.sourceAudioFilename, "recording-boosted.wav"] {
            let candidate = directory.appendingPathComponent(filename)
            if candidate.standardizedFileURL != destination.standardizedFileURL,
               fileManager.fileExists(atPath: candidate.path) {
                try? fileManager.removeItem(at: candidate)
            }
        }
        _ = try update(id: id) { entry in entry.audioAvailability = .available }
        return destination
    }

    func removePartialConvertedAudio(id: UUID) {
        let directory = directoryURL(for: id, staging: false)
        for filename in [Self.canonicalAudioFilename, "recording-boosted.wav"] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(filename))
        }
    }

    func delete(id: UUID, activeIDs: Set<UUID> = []) throws {
        guard !activeIDs.contains(id) else {
            throw RecordingHistoryStoreError.unavailable("This recording is active and cannot be deleted yet.")
        }
        let directory = directoryURL(for: id, staging: false)
        _ = try readEntry(in: directory, expectedID: id)
        try fileManager.removeItem(at: directory)
    }

    @discardableResult
    func reconcileInterruptedWork() throws -> [String] {
        var errors: [String] = []
        let stagingDirectories = try fileManager.contentsOfDirectory(
            at: stagingRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for directory in stagingDirectories {
            do {
                guard try !isSymbolicLink(directory),
                      try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                      let id = UUID(uuidString: directory.lastPathComponent) else {
                    try? fileManager.removeItem(at: directory)
                    continue
                }
                var entry = try readEntry(in: directory, expectedID: id)
                guard let audioURL = validAudioURL(in: directory) else {
                    try? fileManager.removeItem(at: directory)
                    continue
                }
                try setPrivateFilePermissions(at: audioURL)
                let message = "FlowType closed after capture but before processing finished. Retry when ready."
                entry.status = .failed
                entry.stage = .interrupted
                entry.firstError = entry.firstError ?? message
                entry.latestError = message
                entry.audioAvailability = .available
                try write(entry, in: directory)
                let destination = directoryURL(for: id, staging: false)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw RecordingHistoryStoreError.filesystem("A recovered recording duplicated an existing entry.")
                }
                try fileManager.moveItem(at: directory, to: destination)
                try setPrivateDirectoryPermissions(at: destination)
                try secureKnownFiles(in: destination)
            } catch {
                errors.append(error.localizedDescription)
                try? fileManager.removeItem(at: directory)
            }
        }

        let snapshot = try listEntriesWithoutPruning()
        errors.append(contentsOf: snapshot.loadErrors)
        for entry in snapshot.entries where entry.status == .processing {
            do {
                _ = try markInterrupted(id: entry.id)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        try prune()
        return errors
    }

    @discardableResult
    func prune(activeIDs: Set<UUID> = []) throws -> [UUID] {
        let snapshot = try listEntriesWithoutPruning()
        var removed: [UUID] = []
        for entry in snapshot.entries
        where !activeIDs.contains(entry.id)
            && entry.createdAt.addingTimeInterval(Self.retentionInterval) <= now() {
            do {
                try delete(id: entry.id, activeIDs: activeIDs)
                removed.append(entry.id)
            } catch {
                continue
            }
        }
        return removed
    }

    func nextExpiryDate(activeIDs: Set<UUID> = []) throws -> Date? {
        try listEntriesWithoutPruning().entries
            .filter { !activeIDs.contains($0.id) }
            .map { $0.createdAt.addingTimeInterval(Self.retentionInterval) }
            .filter { $0 > now() }
            .min()
    }

    private func listEntriesWithoutPruning() throws -> RecordingHistorySnapshot {
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [RecordingHistoryEntry] = []
        var errors: [String] = []
        for directory in urls {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw RecordingHistoryStoreError.invalidEntry(
                        "Ignored a symlinked recording entry named \(directory.lastPathComponent)."
                    )
                }
                guard values.isDirectory == true,
                      let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                var entry = try readEntry(in: directory, expectedID: id)
                entry.audioAvailability = derivedAudioAvailability(for: entry, in: directory)
                entries.append(entry)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return RecordingHistorySnapshot(entries: entries, loadErrors: errors)
    }

    @discardableResult
    private func update(
        id: UUID,
        mutation: (inout RecordingHistoryEntry) throws -> Void
    ) throws -> RecordingHistoryEntry {
        let directory = directoryURL(for: id, staging: false)
        var entry = try readEntry(in: directory, expectedID: id)
        try mutation(&entry)
        try write(entry, in: directory)
        return entry
    }

    private func readEntry(in directory: URL, expectedID: UUID) throws -> RecordingHistoryEntry {
        guard fileManager.fileExists(atPath: directory.path), try !isSymbolicLink(directory) else {
            throw RecordingHistoryStoreError.invalidEntry("Recording \(expectedID.uuidString) is missing or symlinked.")
        }
        let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
        guard fileManager.fileExists(atPath: metadataURL.path), try !isSymbolicLink(metadataURL) else {
            throw RecordingHistoryStoreError.invalidEntry("Recording \(expectedID.uuidString) has no safe metadata file.")
        }
        guard isNonemptyRegularFile(metadataURL) else {
            throw RecordingHistoryStoreError.invalidEntry("Recording \(expectedID.uuidString) has empty metadata.")
        }
        do {
            let entry = try Self.decoder.decode(RecordingHistoryEntry.self, from: Data(contentsOf: metadataURL))
            guard entry.schemaVersion == RecordingHistoryEntry.currentSchemaVersion else {
                throw RecordingHistoryStoreError.invalidEntry(
                    "Recording \(expectedID.uuidString) uses unsupported metadata version \(entry.schemaVersion)."
                )
            }
            guard entry.id == expectedID else {
                throw RecordingHistoryStoreError.invalidEntry("Recording metadata does not match its directory.")
            }
            return entry
        } catch let error as RecordingHistoryStoreError {
            throw error
        } catch {
            throw RecordingHistoryStoreError.invalidEntry(
                "Recording \(expectedID.uuidString) has malformed metadata: \(error.localizedDescription)"
            )
        }
    }

    private func write(_ entry: RecordingHistoryEntry, in directory: URL) throws {
        guard entry.schemaVersion == RecordingHistoryEntry.currentSchemaVersion else {
            throw RecordingHistoryStoreError.invalidEntry("FlowType cannot write unsupported recording metadata.")
        }
        try prepareDirectory(directory)
        let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
        let data = try Self.encoder.encode(entry)
        do {
            try data.write(to: metadataURL, options: .atomic)
            try setPrivateFilePermissions(at: metadataURL)
        } catch {
            throw RecordingHistoryStoreError.filesystem(
                "FlowType could not save recording metadata: \(error.localizedDescription)"
            )
        }
    }

    private func derivedAudioAvailability(
        for entry: RecordingHistoryEntry,
        in directory: URL
    ) -> RecordingAudioAvailability {
        if entry.audioAvailability == .unusable { return .unusable }
        return validAudioURL(in: directory) == nil ? .missing : .available
    }

    private func validAudioURL(in directory: URL) -> URL? {
        for filename in [Self.canonicalAudioFilename, Self.sourceAudioFilename] {
            let url = directory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard (try? isSymbolicLink(url)) == false, isNonemptyRegularFile(url) else { continue }
            return url
        }
        return nil
    }

    private func isNonemptyRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .isSymbolicLinkKey
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    private func directoryURL(for id: UUID, staging: Bool) -> URL {
        (staging ? stagingRootURL : rootURL)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func prepareDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path), try isSymbolicLink(url) {
            throw RecordingHistoryStoreError.invalidEntry("FlowType refused to use a symlinked recordings directory.")
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try setPrivateDirectoryPermissions(at: url)
        } catch {
            throw RecordingHistoryStoreError.filesystem(
                "FlowType could not prepare private recording storage: \(error.localizedDescription)"
            )
        }
    }

    private func secureKnownFiles(in directory: URL) throws {
        for filename in [Self.metadataFilename, Self.sourceAudioFilename, Self.canonicalAudioFilename] {
            let url = directory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) {
                try setPrivateFilePermissions(at: url)
            }
        }
    }

    private func setPrivateDirectoryPermissions(at url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func setPrivateFilePermissions(at url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
