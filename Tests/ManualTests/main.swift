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
