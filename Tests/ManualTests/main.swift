import Foundation

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
    "normal microphone capture is the reliable default"
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
    let dictionary = PersonalDictionary.parse("""
    Arkis
    whisper flow => Wispr Flow
    arkis
    """)
    expect(dictionary.vocabulary, ["Arkis", "Wispr Flow"], "dictionary de-duplicates vocabulary")
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

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}

print("\nAll manual tests passed")
