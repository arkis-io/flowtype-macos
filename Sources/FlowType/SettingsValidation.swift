import Foundation

enum SettingsValidator {
    static let supportedHotkeyKeys: Set<String> = Set(
        ["fn", "function", "globe", "right_option", "right_command", "right_control", "right_shift", "space", "return", "enter", "tab", "delete", "backspace", "left", "right", "down", "up"]
        + Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
        + Array("0123456789").map(String.init)
        + ["=", "-", "]", "[", "'", ";", "\\", ",", "/", ".", "`"]
    )

    static let supportedModifiers: Set<String> = [
        "command", "cmd", "control", "ctrl", "option", "alt", "shift", "fn", "function", "globe"
    ]

    static func validate(_ config: AppConfig) throws {
        try validateHotkey(config.hotkey)
        try validateHotkey(config.toggleHotkey)
        guard config.gestures.hybridPrimaryHotkey
                || hotkeySignature(config.hotkey) != hotkeySignature(config.toggleHotkey) else {
            throw FlowTypeError.configuration("Push to talk and hands-free toggle must use different shortcuts.")
        }

        guard (60...300).contains(config.gestures.maxRecordingSeconds) else {
            throw FlowTypeError.configuration("Auto-stop must be between one and five minutes.")
        }
        guard config.gestures.doubleTapIntervalMilliseconds >= 150,
              config.gestures.doubleTapIntervalMilliseconds <= 750 else {
            throw FlowTypeError.configuration("The double-tap interval must be between 150 and 750 milliseconds.")
        }
        guard config.gestures.quickTapMaxDurationMilliseconds >= 120,
              config.gestures.quickTapMaxDurationMilliseconds <= 600 else {
            throw FlowTypeError.configuration("The quick-tap duration must be between 120 and 600 milliseconds.")
        }

        guard ["default", "min", "mid", "max"].contains(config.audio.duckingLevel.lowercased()) else {
            throw FlowTypeError.configuration("Audio ducking must be default, min, mid, or max.")
        }
        guard !config.audio.inputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowTypeError.configuration("The microphone preference cannot be empty.")
        }

        let transcriptionProvider = config.transcription.provider.lowercased()
        guard ["local", "openai", "groq"].contains(transcriptionProvider) else {
            throw FlowTypeError.configuration("Transcription provider must be local, openai, or groq.")
        }
        guard !config.transcription.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowTypeError.configuration("Transcription language cannot be empty.")
        }
        if transcriptionProvider == "local" {
            guard !config.transcription.localExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !config.transcription.localModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FlowTypeError.configuration("Local transcription requires both a whisper-cli path and a model path.")
            }
        }

        if config.cleanup.enabled {
            guard ["local", "openai", "groq"].contains(config.cleanup.provider.lowercased()) else {
                throw FlowTypeError.configuration("Cleanup provider must be local, openai, or groq.")
            }
            guard !config.cleanup.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FlowTypeError.configuration("Cleanup model cannot be empty while cleanup is enabled.")
            }
            guard let url = URL(string: config.cleanup.baseURL),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw FlowTypeError.configuration("Cleanup base URL must be a valid http or https URL.")
            }
        }

        guard config.clipboard.restoreDelayMilliseconds >= 0,
              config.clipboard.restoreDelayMilliseconds <= 5_000 else {
            throw FlowTypeError.configuration("Clipboard restoration delay must be between 0 and 5000 milliseconds.")
        }
    }

    static func validateHotkey(_ hotkey: HotkeyConfig) throws {
        let key = hotkey.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportedHotkeyKeys.contains(key) else {
            throw FlowTypeError.configuration("Unsupported hotkey key '\(hotkey.key)'.")
        }
        guard key != "escape", key != "esc" else {
            throw FlowTypeError.configuration("Escape is reserved for cancelling dictation.")
        }

        for modifier in hotkey.modifiers.map({ $0.lowercased() }) {
            guard supportedModifiers.contains(modifier) else {
                throw FlowTypeError.configuration("Unsupported hotkey modifier '\(modifier)'.")
            }
        }

        let standaloneKeys = [
            "fn", "function", "globe", "right_option", "right_command", "right_control", "right_shift"
        ]
        if standaloneKeys.contains(key), !hotkey.modifiers.isEmpty {
            throw FlowTypeError.configuration("Fn and side-specific modifier keys must be used by themselves.")
        }
    }

    private static func hotkeySignature(_ hotkey: HotkeyConfig) -> String {
        let rawKey = hotkey.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ["function", "globe"].contains(rawKey) ? "fn" : rawKey
        let modifiers = hotkey.modifiers.map { modifier -> String in
            switch modifier.lowercased() {
            case "cmd": return "command"
            case "ctrl": return "control"
            case "alt": return "option"
            case "function", "globe": return "fn"
            default: return modifier.lowercased()
            }
        }.sorted()
        return ([key] + modifiers).joined(separator: "+")
    }
}
