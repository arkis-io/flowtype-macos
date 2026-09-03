import Foundation
import CoreAudio

private var failures = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private final class FakeOutputVolumeController: OutputVolumeControlling {
    let control = OutputVolumeControl(
        deviceUID: "test-output",
        deviceName: "Test Speakers",
        element: 0
    )
    var currentVolume: Float32
    var isAvailable = true
    var allowsChanges = true

    init(volume: Float32) {
        currentVolume = volume
    }

    func defaultOutputControl() -> OutputVolumeControl? {
        isAvailable ? control : nil
    }

    func volume(for control: OutputVolumeControl) -> Float32? {
        isAvailable && control == self.control ? currentVolume : nil
    }

    func setVolume(_ volume: Float32, for control: OutputVolumeControl) -> Bool {
        guard isAvailable, allowsChanges, control == self.control else { return false }
        currentVolume = volume
        return true
    }
}

let config = AppConfig.defaultConfig.gestures
var legacyConfig = config
legacyConfig.hybridPrimaryHotkey = false

expect(
    AppConfig.defaultConfig.audio.voiceProcessingEnabled,
    false,
    "the retired AVAudioEngine voice-processing path stays disabled"
)
expect(
    AppConfig.defaultConfig.audio.boostQuietSpeechEnabled,
    true,
    "quiet-speech gain is enabled by default"
)
expect(
    AppConfig.defaultConfig.audio.preferBuiltInMicWithBluetoothOutput,
    true,
    "automatic routing avoids a Bluetooth headset microphone while listening"
)
expect(
    AppConfig.defaultConfig.updates.checkAutomatically,
    true,
    "public release checks are enabled by default"
)
expect(
    AppConfig.defaultConfig.transcription.localExecutable,
    "bundled",
    "new installs use FlowType's bundled offline engine"
)
expect(
    URL(fileURLWithPath: AppConfig.defaultConfig.transcription.localModelPath).lastPathComponent,
    "ggml-medium.en.bin",
    "new installs recommend the more accurate medium English model"
)
expect(
    AudioSignalQuality.isNearSilent(peakAmplitude: 0.00003),
    true,
    "near-digital silence is rejected before transcription"
)
expect(
    AudioSignalQuality.isNearSilent(peakAmplitude: 0.001),
    false,
    "quiet but usable audio is accepted"
)
expect(
    AudioSignalQuality.gainForQuietSpeech(peakAmplitude: 0.05),
    4,
    "quiet-speech boost is capped so background noise cannot be amplified without limit"
)
expect(
    AudioSignalQuality.gainForQuietSpeech(peakAmplitude: 0.5),
    1,
    "healthy speech is not amplified"
)
expect(
    TranscriptQuality.isOnlyNonSpeechMarkers("(inaudible) (inaudible)"),
    true,
    "inaudible markers are rejected before insertion"
)
expect(
    TranscriptQuality.isOnlyNonSpeechMarkers("(laughing)"),
    true,
    "laughter-only markers are rejected before insertion"
)
expect(
    TranscriptQuality.isOnlyNonSpeechMarkers("[background music]"),
    true,
    "background-music-only markers are rejected before insertion"
)
expect(
    TranscriptQuality.isOnlyNonSpeechMarkers("Please play music"),
    false,
    "ordinary speech is not mistaken for a non-speech marker"
)

do {
    expect(
        LocalModelSpecification.smallEnglish.expectedByteCount,
        487_614_201,
        "offline model size is pinned"
    )
    expect(
        LocalModelSpecification.smallEnglish.expectedSHA256,
        "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        "offline model checksum is pinned"
    )
    expect(
        LocalModelSpecification.mediumEnglish.expectedByteCount,
        1_533_774_781,
        "recommended medium model size is pinned"
    )
    expect(
        LocalModelSpecification.mediumEnglish.expectedSHA256,
        "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
        "recommended medium model checksum is pinned"
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowTypeModelVerifier-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("fixture.bin")
    try? Data("abc".utf8).write(to: sourceURL)
    let fixture = LocalModelSpecification(
        filename: "fixture.bin",
        downloadURL: URL(string: "https://example.com/fixture.bin")!,
        expectedByteCount: 3,
        expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    var validFixturePassed = false
    do {
        try LocalModelFileVerifier.verify(sourceURL, specification: fixture)
        validFixturePassed = true
    } catch {}
    expect(validFixturePassed, true, "a model with the pinned size and checksum is accepted")

    let wrongChecksum = LocalModelSpecification(
        filename: fixture.filename,
        downloadURL: fixture.downloadURL,
        expectedByteCount: fixture.expectedByteCount,
        expectedSHA256: String(repeating: "0", count: 64)
    )
    var corruptFixtureRejected = false
    do {
        try LocalModelFileVerifier.verify(sourceURL, specification: wrongChecksum)
    } catch {
        corruptFixtureRejected = true
    }
    expect(corruptFixtureRejected, true, "a model with the wrong checksum is rejected")

    let existingURL = directory.appendingPathComponent("installed.bin")
    let badStagingURL = directory.appendingPathComponent("bad-download.bin")
    try? Data("old".utf8).write(to: existingURL)
    try? Data("bad".utf8).write(to: badStagingURL)
    do {
        try LocalModelFileVerifier.installVerifiedFile(
            stagingURL: badStagingURL,
            destinationURL: existingURL,
            specification: fixture
        )
    } catch {}
    expect(
        try? String(contentsOf: existingURL, encoding: .utf8),
        "old",
        "a corrupt or interrupted download cannot replace a working model"
    )

    let goodStagingURL = directory.appendingPathComponent("good-download.bin")
    try? Data("abc".utf8).write(to: goodStagingURL)
    var verifiedReplacementPassed = false
    do {
        try LocalModelFileVerifier.installVerifiedFile(
            stagingURL: goodStagingURL,
            destinationURL: existingURL,
            specification: fixture
        )
        verifiedReplacementPassed = (try? String(contentsOf: existingURL, encoding: .utf8)) == "abc"
    } catch {}
    expect(verifiedReplacementPassed, true, "a verified model atomically replaces the previous file")
}

do {
    let airPods = AudioInputDevice(
        id: 10,
        uid: "airpods",
        name: "AirPods Microphone",
        transportType: kAudioDeviceTransportTypeBluetooth
    )
    let macMicrophone = AudioInputDevice(
        id: 20,
        uid: "mac-mic",
        name: "MacBook Pro Microphone",
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    expect(
        AudioDeviceService.preferredAutomaticInput(
            defaultInput: airPods,
            availableInputs: [airPods, macMicrophone],
            bluetoothOutputActive: true,
            avoidBluetoothHeadsetMic: true
        ),
        macMicrophone,
        "automatic routing uses the Mac microphone when AirPods handle output"
    )
    expect(
        AudioDeviceService.preferredAutomaticInput(
            defaultInput: airPods,
            availableInputs: [airPods, macMicrophone],
            bluetoothOutputActive: false,
            avoidBluetoothHeadsetMic: true
        ),
        airPods,
        "automatic routing keeps the default input when Bluetooth output is inactive"
    )
}

do {
    expect(ReleaseVersion("v0.6.0"), ReleaseVersion("0.6"), "release versions ignore a leading v and trailing zero")
    expect(
        ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!,
        true,
        "release versions compare numerically"
    )
    expect(ReleaseVersion("version-six"), nil, "invalid release versions are rejected")

    let availableJSON = Data("""
    {
      "tag_name": "v0.7.0",
      "name": "FlowType 0.7.0",
      "body": "A safer update.",
      "html_url": "https://github.com/jdlinventures/flowtype-macos/releases/tag/v0.7.0"
    }
    """.utf8)
    let release = FlowTypeRelease(
        version: "0.7.0",
        title: "FlowType 0.7.0",
        notes: "A safer update.",
        webpageURL: URL(string: "https://github.com/jdlinventures/flowtype-macos/releases/tag/v0.7.0")!
    )
    expect(
        try? ReleaseUpdateChecker.outcome(from: availableJSON, currentVersion: ReleaseVersion("0.6.0")!),
        .updateAvailable(release),
        "newer GitHub releases are offered"
    )
    expect(
        try? ReleaseUpdateChecker.outcome(from: availableJSON, currentVersion: ReleaseVersion("0.7.0")!),
        .upToDate(release),
        "the installed GitHub release reports up to date"
    )
    expect(
        ReleaseUpdateChecker.shouldCheckAutomatically(
            lastCheck: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 100 + 23 * 60 * 60)
        ),
        false,
        "automatic release checks wait 24 hours"
    )
    expect(
        ReleaseUpdateChecker.shouldCheckAutomatically(
            lastCheck: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 100 + 24 * 60 * 60)
        ),
        true,
        "automatic release checks resume after 24 hours"
    )
}

do {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowTypeVolumeTest-\(UUID().uuidString)", isDirectory: true)
    let recoveryURL = testDirectory.appendingPathComponent("recovery.json")
    defer { try? FileManager.default.removeItem(at: testDirectory) }

    let backend = FakeOutputVolumeController(volume: 0.8)
    let ducker = OutputVolumeDucker(recoveryURL: recoveryURL, backend: backend)
    expect(ducker.begin(enabled: true, level: "mid"), true, "music lowering starts on a supported output")
    expect(Int((backend.currentVolume * 1_000).rounded()), 280, "medium lowering keeps 35 percent of the prior volume")
    expect(FileManager.default.fileExists(atPath: recoveryURL.path), true, "original volume is persisted before lowering")
    expect(ducker.restoreIfNeeded(), true, "music volume restores after recording")
    expect(Int((backend.currentVolume * 1_000).rounded()), 800, "restoration returns the exact previous volume")
    expect(FileManager.default.fileExists(atPath: recoveryURL.path), false, "successful restoration clears recovery state")
}

do {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowTypeCrashRecoveryTest-\(UUID().uuidString)", isDirectory: true)
    let recoveryURL = testDirectory.appendingPathComponent("recovery.json")
    defer { try? FileManager.default.removeItem(at: testDirectory) }

    let backend = FakeOutputVolumeController(volume: 0.6)
    let firstProcess = OutputVolumeDucker(recoveryURL: recoveryURL, backend: backend)
    expect(firstProcess.begin(enabled: true, level: "max"), true, "strong lowering starts before simulated crash")

    let relaunchedProcess = OutputVolumeDucker(recoveryURL: recoveryURL, backend: backend)
    expect(relaunchedProcess.restoreIfNeeded(), true, "next launch restores volume after a simulated crash")
    expect(Int((backend.currentVolume * 1_000).rounded()), 600, "crash recovery restores the pre-recording volume")
}

do {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowTypeUnsupportedOutputTest-\(UUID().uuidString)", isDirectory: true)
    let recoveryURL = testDirectory.appendingPathComponent("recovery.json")
    defer { try? FileManager.default.removeItem(at: testDirectory) }

    let backend = FakeOutputVolumeController(volume: 0.9)
    backend.isAvailable = false
    let ducker = OutputVolumeDucker(recoveryURL: recoveryURL, backend: backend)
    expect(ducker.begin(enabled: true, level: "mid"), false, "unsupported output safely skips music lowering")
    expect(Int((backend.currentVolume * 1_000).rounded()), 900, "unsupported output does not alter volume")
}

do {
    var machine = GestureStateMachine()
    expect(
        machine.handle(.hotkeyDown(at: 10), config: config),
        [.startRecording, .showHeldMode],
        "hold starts recording"
    )
    expect(
        machine.handle(.hotkeyUp(at: 11), config: config),
        [.stopAndProcess],
        "release stops a held recording"
    )
}

do {
    expect(
        PermissionSetupStep.next(
            microphoneAllowed: false,
            inputMonitoringAllowed: false,
            accessibilityAllowed: false
        ),
        .microphone,
        "permission setup starts with microphone"
    )
    expect(
        PermissionSetupStep.next(
            microphoneAllowed: true,
            inputMonitoringAllowed: false,
            accessibilityAllowed: false
        ),
        .inputMonitoring,
        "permission setup advances to Input Monitoring"
    )
    expect(
        PermissionSetupStep.next(
            microphoneAllowed: true,
            inputMonitoringAllowed: true,
            accessibilityAllowed: false
        ),
        .accessibility,
        "permission setup advances to Accessibility"
    )
    expect(
        PermissionSetupStep.next(
            microphoneAllowed: true,
            inputMonitoringAllowed: true,
            accessibilityAllowed: true
        ),
        .ready,
        "permission setup finishes only when all three are allowed"
    )
}

do {
    var machine = GestureStateMachine()
    expect(
        machine.handle(.toggleHotkeyDown(at: 20), config: legacyConfig),
        [.startRecording, .showHandsFreeMode],
        "dedicated toggle starts hands-free recording"
    )
    expect(
        machine.handle(.toggleHotkeyDown(at: 22), config: legacyConfig),
        [.stopAndProcess],
        "dedicated toggle stops hands-free recording"
    )
}

do {
    var machine = GestureStateMachine()
    _ = machine.handle(.hotkeyDown(at: 10), config: config)
    expect(
        machine.handle(.hotkeyUp(at: 10.1), config: config),
        [.showHandsFreeMode],
        "quick tap enters hands-free mode"
    )
    expect(machine.handle(.hotkeyDown(at: 12), config: config), [.stopAndProcess], "one more tap stops hands-free")
}

do {
    var machine = GestureStateMachine()
    _ = machine.handle(.hotkeyDown(at: 1), config: legacyConfig)
    _ = machine.handle(.hotkeyUp(at: 1.1), config: legacyConfig)
    expect(machine.handle(.doubleTapWindowExpired(at: 1.2), config: legacyConfig), [], "early timer event is ignored")
    expect(machine.handle(.doubleTapWindowExpired(at: 1.42), config: legacyConfig), [.stopAndProcess], "legacy single tap stops after double-tap window")
}

do {
    var machine = GestureStateMachine()
    _ = machine.handle(.hotkeyDown(at: 1), config: config)
    expect(
        machine.handle(.escape, config: config),
        [.cancelDoubleTapExpiry, .cancel, .hide],
        "escape cancels recording"
    )
    expect(machine.phase, .idle, "escape returns to idle")
}

do {
    var machine = GestureStateMachine()
    _ = machine.handle(.hotkeyDown(at: 1), config: config)
    _ = machine.handle(.hotkeyUp(at: 1.1), config: config)
    expect(
        machine.handle(.autoStop, config: config),
        [.cancelDoubleTapExpiry, .stopAndProcess],
        "five-minute timer stops hands-free recording"
    )
    expect(
        machine.handle(.escape, config: config),
        [.cancelDoubleTapExpiry, .cancel, .hide],
        "escape cancels in-flight processing"
    )
}

do {
    var machine = GestureStateMachine()
    expect(
        machine.handle(.beginExternalProcessing, config: config),
        [],
        "an idle machine accepts external retry processing without capture actions"
    )
    expect(machine.phase, .processing, "external retry enters processing")
    expect(
        machine.handle(.beginExternalProcessing, config: config),
        [],
        "a second external retry is ignored while processing"
    )
    expect(
        machine.handle(.processingFinished, config: config),
        [.hide],
        "external retry completion returns to idle"
    )

    for event in [
        GestureStateMachine.Event.hotkeyDown(at: 1),
        .hotkeyUp(at: 1.1)
    ] {
        _ = machine.handle(event, config: config)
    }
    expect(
        machine.handle(.beginExternalProcessing, config: config),
        [],
        "external retry is ignored while hands-free recording is active"
    )
    expect(
        machine.phase,
        .handsFree(startedAt: 1),
        "ignored external retry does not disturb recording state"
    )
}

do {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("FlowTypeHistoryTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }

    var currentDate = Date(timeIntervalSince1970: 1_000_000)
    let store = try RecordingHistoryStore(rootURL: directory, now: { currentDate })
    let olderID = UUID()
    let older = try store.beginCapture(id: olderID, createdAt: currentDate.addingTimeInterval(-60))
    try Data("caf-audio".utf8).write(to: older.audioURL)
    _ = try store.promoteCapture(id: olderID, durationSeconds: 3.25)
    let newerID = UUID()
    let newer = try store.beginCapture(id: newerID, createdAt: currentDate)
    try Data("caf-audio".utf8).write(to: newer.audioURL)
    _ = try store.promoteCapture(id: newerID, durationSeconds: 1.5)

    let ordered = try store.listEntries().entries
    expect(ordered.map(\.id), [newerID, olderID], "recording history is newest first")
    expect(ordered.first?.schemaVersion, 1, "recording metadata uses schema version 1")
    expect(ordered.first?.durationSeconds, 1.5, "recording duration round-trips")

    _ = try store.beginAttempt(id: newerID, provider: "local", at: currentDate)
    _ = try store.failAttempt(id: newerID, stage: .transcription, message: "first failure")
    _ = try store.beginAttempt(id: newerID, provider: "groq", at: currentDate.addingTimeInterval(2))
    let retried = try store.failAttempt(id: newerID, stage: .cleanup, message: "latest failure")
    expect(retried.firstError, "first failure", "the original recording error stays immutable")
    expect(retried.latestError, "latest failure", "the latest retry error is updated")
    expect(retried.originalProvider, "local", "the original provider stays immutable")
    expect(retried.latestProvider, "groq", "the latest provider follows current retry settings")
    expect(retried.attemptCount, 2, "retry attempts increment on the same entry")
    let originalCreatedAt = retried.createdAt
    currentDate = currentDate.addingTimeInterval(120)
    expect(
        try store.loadEntry(id: newerID).createdAt,
        originalCreatedAt,
        "retry never extends the original three-day retention clock"
    )
    if case .available = try store.retryEligibility(for: newerID) {
        expect(true, true, "a retained nonempty recording is retryable")
    } else {
        expect(false, true, "a retained nonempty recording is retryable")
    }

    let rootMode = (try fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
    let metadataURL = directory.appendingPathComponent(newerID.uuidString)
        .appendingPathComponent(RecordingHistoryStore.metadataFilename)
    let metadataMode = (try fileManager.attributesOfItem(atPath: metadataURL.path)[.posixPermissions] as? NSNumber)?.intValue
    expect(rootMode, 0o700, "recording history root uses private directory permissions")
    expect(metadataMode, 0o600, "recording metadata uses private file permissions")

    let activeExpiredID = UUID()
    let activeExpired = try store.beginCapture(
        id: activeExpiredID,
        createdAt: currentDate.addingTimeInterval(-RecordingHistoryStore.retentionInterval)
    )
    try Data("caf-audio".utf8).write(to: activeExpired.audioURL)
    _ = try store.promoteCapture(id: activeExpiredID, durationSeconds: 1)
    _ = try store.prune(activeIDs: [activeExpiredID])
    expect(
        (try? store.loadEntry(id: activeExpiredID)) != nil,
        true,
        "active work is excluded from expiry pruning"
    )
    _ = try store.prune()
    expect(
        (try? store.loadEntry(id: activeExpiredID)) == nil,
        true,
        "the exact three-day boundary expires an inactive entry"
    )

    let staleID = UUID()
    let stale = try store.beginCapture(id: staleID, createdAt: currentDate)
    try Data("caf-audio".utf8).write(to: stale.audioURL)
    let reconciliationErrors = try store.reconcileInterruptedWork()
    expect(reconciliationErrors.isEmpty, true, "valid stale staging is recovered without a load error")
    let recovered = try store.loadEntry(id: staleID)
    expect(recovered.stage, .interrupted, "stale finalized staging is marked interrupted")
    expect(recovered.status, .failed, "stale finalized staging remains retryable as failed")

    let processingID = UUID()
    let processing = try store.beginCapture(id: processingID, createdAt: currentDate)
    try Data("caf-audio".utf8).write(to: processing.audioURL)
    _ = try store.promoteCapture(id: processingID, durationSeconds: 1)
    _ = try store.beginAttempt(id: processingID, provider: "local")
    _ = try store.reconcileInterruptedWork()
    expect(try store.loadEntry(id: processingID).stage, .interrupted, "stale processing is marked interrupted")

    try store.delete(id: olderID)
    expect((try? store.loadEntry(id: olderID)) == nil, true, "delete removes only the selected recording")
    expect((try? store.loadEntry(id: newerID)) != nil, true, "delete leaves other recordings intact")

    let malformedID = UUID()
    let malformedDirectory = directory.appendingPathComponent(malformedID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
    try Data("null".utf8).write(
        to: malformedDirectory.appendingPathComponent(RecordingHistoryStore.metadataFilename)
    )
    let malformedSnapshot = try store.listEntries()
    expect(
        malformedSnapshot.entries.contains { $0.id == malformedID },
        false,
        "malformed metadata is quarantined from visible history"
    )
    expect(malformedSnapshot.loadErrors.isEmpty, false, "malformed metadata produces a nonfatal load error")
}

do {
    expect(
        RecordingCancellationPolicy.disposition(for: .capture, cause: .escape),
        .delete,
        "Escape deletes an unfinished capture"
    )
    expect(
        RecordingCancellationPolicy.disposition(for: .capture, cause: .lifecycle),
        .delete,
        "lifecycle cancellation deletes an unfinished capture"
    )
    expect(
        RecordingCancellationPolicy.disposition(for: .initialProcessing, cause: .escape),
        .delete,
        "Escape deletes a new initial-processing entry"
    )
    expect(
        RecordingCancellationPolicy.disposition(for: .initialProcessing, cause: .lifecycle),
        .retainInterrupted,
        "lifecycle interruption retains finalized initial audio"
    )
    expect(
        RecordingCancellationPolicy.disposition(for: .retry, cause: .escape),
        .retainInterrupted,
        "Escape retains a retry source"
    )
    expect(
        RecordingCancellationPolicy.disposition(for: .retry, cause: .lifecycle),
        .retainInterrupted,
        "lifecycle interruption retains a retry source"
    )
}

do {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("FlowTypeHistoryInvalidTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    let store = try RecordingHistoryStore(rootURL: directory)
    expect(try store.listEntries().entries.isEmpty, true, "an absent or empty history root loads safely")

    let missingAudioID = UUID()
    let missingAudioCapture = try store.beginCapture(id: missingAudioID)
    try Data("audio".utf8).write(to: missingAudioCapture.audioURL)
    _ = try store.promoteCapture(id: missingAudioID, durationSeconds: 1)
    try fileManager.removeItem(at: directory.appendingPathComponent(missingAudioID.uuidString)
        .appendingPathComponent(RecordingHistoryStore.sourceAudioFilename))
    if case .unavailable = try store.retryEligibility(for: missingAudioID) {
        expect(true, true, "missing retained audio is not retryable")
    } else {
        expect(false, true, "missing retained audio is not retryable")
    }

    let unusableID = UUID()
    let unusableCapture = try store.beginCapture(id: unusableID)
    try Data("audio".utf8).write(to: unusableCapture.audioURL)
    _ = try store.promoteCapture(id: unusableID, durationSeconds: 1)
    _ = try store.failAttempt(
        id: unusableID,
        stage: .conversion,
        message: "nearly silent",
        unusableAudio: true
    )
    if case .unavailable = try store.retryEligibility(for: unusableID) {
        expect(true, true, "known unusable audio is not retryable")
    } else {
        expect(false, true, "known unusable audio is not retryable")
    }

    let transcriptID = UUID()
    let transcriptCapture = try store.beginCapture(id: transcriptID)
    try Data("audio".utf8).write(to: transcriptCapture.audioURL)
    _ = try store.promoteCapture(id: transcriptID, durationSeconds: 1)
    _ = try store.beginAttempt(id: transcriptID, provider: "local")
    _ = try store.completeAttempt(id: transcriptID, rawTranscript: "raw", finalTranscript: "final")
    _ = try store.beginAttempt(id: transcriptID, provider: "openai")
    _ = try store.failAttempt(id: transcriptID, stage: .transcription, message: "retry failed")
    expect(
        try store.loadEntry(id: transcriptID).finalTranscript,
        "final",
        "a failed retry preserves the prior completed transcript"
    )

    let emptyStagingID = UUID()
    _ = try store.beginCapture(id: emptyStagingID)
    _ = try store.reconcileInterruptedWork()
    expect(
        fileManager.fileExists(atPath: directory.appendingPathComponent(".staging")
            .appendingPathComponent(emptyStagingID.uuidString).path),
        false,
        "audio-less stale staging is removed as incomplete capture"
    )

    let invalidCases: [(String, Data?)] = [
        ("missing", nil),
        ("zero", Data()),
        ("malformed", Data("{".utf8)),
        ("null", Data("null".utf8)),
        ("missing-schema", Data("{\"id\":\"\(UUID().uuidString)\"}".utf8)),
        ("unsupported", Data("{\"schemaVersion\":99}".utf8))
    ]
    for (_, metadata) in invalidCases {
        let id = UUID()
        let entryDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        if let metadata {
            try metadata.write(to: entryDirectory.appendingPathComponent(RecordingHistoryStore.metadataFilename))
        }
    }

    let mismatchSourceID = UUID()
    let mismatchCapture = try store.beginCapture(id: mismatchSourceID)
    try Data("audio".utf8).write(to: mismatchCapture.audioURL)
    _ = try store.promoteCapture(id: mismatchSourceID, durationSeconds: 1)
    let mismatchDirectoryID = UUID()
    let mismatchDirectory = directory.appendingPathComponent(mismatchDirectoryID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: mismatchDirectory, withIntermediateDirectories: true)
    try fileManager.copyItem(
        at: directory.appendingPathComponent(mismatchSourceID.uuidString)
            .appendingPathComponent(RecordingHistoryStore.metadataFilename),
        to: mismatchDirectory.appendingPathComponent(RecordingHistoryStore.metadataFilename)
    )

    let symlinkID = UUID()
    try fileManager.createSymbolicLink(
        at: directory.appendingPathComponent(symlinkID.uuidString),
        withDestinationURL: directory.appendingPathComponent(mismatchSourceID.uuidString)
    )
    let invalidSnapshot = try store.listEntries()
    expect(
        invalidSnapshot.loadErrors.count >= invalidCases.count + 2,
        true,
        "missing, empty, malformed, unsupported, mismatched, and symlinked metadata are reported nonfatally"
    )

    let zeroAudioID = UUID()
    let zeroAudioCapture = try store.beginCapture(id: zeroAudioID)
    try Data().write(to: zeroAudioCapture.audioURL)
    expect(
        (try? store.promoteCapture(id: zeroAudioID, durationSeconds: 0)) == nil,
        true,
        "zero-byte audio cannot be promoted into visible history"
    )
}

do {
    let dictionary = PersonalDictionary.parse("""
    Arkis
    whisper flow => Wispr Flow
    arkis
    """)
    expect(dictionary.vocabulary, ["Arkis", "Wispr Flow"], "dictionary de-duplicates vocabulary")
    expect(
        dictionary.isRecognitionPromptEcho("Arkis, Wispr Flow"),
        true,
        "a dictionary-only recognition prompt echo is rejected"
    )
    expect(
        dictionary.isRecognitionPromptEcho("Send the Arkis notes through Wispr Flow"),
        false,
        "real speech containing dictionary terms is preserved"
    )
    expect(
        dictionary.applyingReplacements(to: "Try WHISPER FLOW, not whisper flowing."),
        "Try Wispr Flow, not whisper flowing.",
        "dictionary replacements use whole phrases"
    )
}

do {
    var valid = AppConfig.defaultConfig
    expect((try? SettingsValidator.validate(valid)) != nil, true, "default settings validate")

    valid.hotkey = HotkeyConfig(key: "space", modifiers: ["control", "option"])
    expect((try? SettingsValidator.validate(valid)) != nil, true, "custom shortcut validates")

    valid.hotkey = HotkeyConfig(key: "fn", modifiers: ["command"])
    expect((try? SettingsValidator.validate(valid)) == nil, true, "Fn rejects extra modifiers")

    valid = AppConfig.defaultConfig
    valid.hotkey = HotkeyConfig(key: "right_option", modifiers: [])
    valid.toggleHotkey = HotkeyConfig(key: "fn", modifiers: [])
    expect((try? SettingsValidator.validate(valid)) != nil, true, "Right Option validates as a standalone key")

    valid.hotkey = HotkeyConfig(key: "right_option", modifiers: ["command"])
    expect((try? SettingsValidator.validate(valid)) == nil, true, "Right Option rejects extra modifiers")

    valid = AppConfig.defaultConfig
    valid.toggleHotkey = valid.hotkey
    valid.gestures.hybridPrimaryHotkey = false
    expect((try? SettingsValidator.validate(valid)) == nil, true, "recording shortcuts must be different")

    valid.gestures.hybridPrimaryHotkey = true
    expect((try? SettingsValidator.validate(valid)) != nil, true, "hybrid mode can ignore a duplicate secondary shortcut")

    valid = AppConfig.defaultConfig
    valid.gestures.maxRecordingSeconds = 301
    expect((try? SettingsValidator.validate(valid)) == nil, true, "auto-stop cannot exceed five minutes")

    valid = AppConfig.defaultConfig
    valid.audio.inputDeviceUID = "   "
    expect((try? SettingsValidator.validate(valid)) == nil, true, "microphone preference cannot be empty")
}

do {
    var config = AppConfig.defaultConfig
    config.transcription.provider = "local"
    config.cleanup.enabled = false
    expect(RetryCostNotice.summary(for: config) == nil, true, "local-only retry shows no cost notice")

    config.cleanup.enabled = true
    config.cleanup.provider = "local"
    expect(RetryCostNotice.summary(for: config) == nil, true, "local cleanup endpoint shows no cost notice")

    config.transcription.provider = "OpenAI"
    config.cleanup.enabled = false
    let transcriptionOnly = RetryCostNotice.summary(for: config)
    expect(transcriptionOnly?.providers ?? [], ["OpenAI"], "cloud transcription names its provider")
    expect(transcriptionOnly?.message.contains("retained audio") ?? false, true, "cloud transcription notice mentions re-sending audio")

    config.transcription.provider = "local"
    config.cleanup.enabled = true
    config.cleanup.provider = "groq"
    let cleanupOnly = RetryCostNotice.summary(for: config)
    expect(cleanupOnly?.providers ?? [], ["Groq"], "cloud cleanup names its provider")
    expect(cleanupOnly?.message.contains("transcript") ?? false, true, "cloud cleanup notice mentions re-sending the transcript")

    config.transcription.provider = "groq"
    expect(RetryCostNotice.summary(for: config)?.providers ?? [], ["Groq"], "same provider for both stages is listed once")

    config.transcription.provider = "openai"
    expect(RetryCostNotice.summary(for: config)?.providers ?? [], ["OpenAI", "Groq"], "distinct providers are listed in pipeline order")
    expect(RetryCostNotice.summary(for: config)?.message.hasPrefix("Retrying will send the retained audio to OpenAI") ?? false, true, "notice message starts with the transcription action")
}

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}

print("\nAll manual tests passed")
