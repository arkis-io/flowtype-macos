import Foundation

struct AppConfig: Codable, Equatable {
    var enabled: Bool
    var hotkey: HotkeyConfig
    var toggleHotkey: HotkeyConfig
    var gestures: GestureConfig
    var audio: AudioConfig
    var transcription: TranscriptionConfig
    var cleanup: CleanupConfig
    var clipboard: ClipboardConfig
    var updates: UpdateConfig
    var dictionaryPath: String

    static let defaultConfig = AppConfig(
        enabled: true,
        hotkey: HotkeyConfig(key: "right_option", modifiers: []),
        toggleHotkey: HotkeyConfig(key: "fn", modifiers: []),
        gestures: GestureConfig(
            hybridPrimaryHotkey: true,
            doubleTapIntervalMilliseconds: 320,
            quickTapMaxDurationMilliseconds: 240,
            maxRecordingSeconds: 300
        ),
        audio: AudioConfig(
            feedbackSoundsEnabled: true,
            voiceProcessingEnabled: false,
            lowerOtherAudioEnabled: true,
            duckingLevel: "mid",
            inputDeviceUID: "system_default",
            inputDeviceName: ""
        ),
        transcription: TranscriptionConfig(
            provider: "local",
            language: "en",
            localExecutable: "bundled",
            localModelPath: "~/Library/Application Support/FlowType/models/ggml-small.en.bin",
            openAIModel: "whisper-1",
            groqModel: "whisper-large-v3-turbo"
        ),
        cleanup: CleanupConfig(
            enabled: true,
            provider: "openai",
            baseURL: "https://api.openai.com/v1",
            model: "gpt-5-mini",
            prompt: "Remove filler words, fix punctuation, and preserve the speaker's meaning. Match capitalization to the apparent dictation style. Keep names, technical terms, numbers, and formatting intact. Return only the cleaned text.",
            fallbackToRawOnError: true
        ),
        clipboard: ClipboardConfig(
            restorePrevious: false,
            restoreDelayMilliseconds: 500
        ),
        updates: UpdateConfig(
            checkAutomatically: true
        ),
        dictionaryPath: "~/Library/Application Support/FlowType/dictionary.txt"
    )
}

struct HotkeyConfig: Codable, Equatable {
    var key: String
    var modifiers: [String]
}

struct GestureConfig: Codable, Equatable {
    var hybridPrimaryHotkey: Bool
    var doubleTapIntervalMilliseconds: Int
    var quickTapMaxDurationMilliseconds: Int
    var maxRecordingSeconds: Int

    var doubleTapInterval: TimeInterval {
        TimeInterval(doubleTapIntervalMilliseconds) / 1_000
    }

    var quickTapMaxDuration: TimeInterval {
        TimeInterval(quickTapMaxDurationMilliseconds) / 1_000
    }
}

struct AudioConfig: Codable, Equatable {
    var feedbackSoundsEnabled: Bool
    var voiceProcessingEnabled: Bool
    var lowerOtherAudioEnabled: Bool
    var duckingLevel: String
    var inputDeviceUID: String
    var inputDeviceName: String
}

struct TranscriptionConfig: Codable, Equatable {
    var provider: String
    var language: String
    var localExecutable: String
    var localModelPath: String
    var openAIModel: String
    var groqModel: String
}

struct CleanupConfig: Codable, Equatable {
    var enabled: Bool
    var provider: String
    var baseURL: String
    var model: String
    var prompt: String
    var fallbackToRawOnError: Bool
}

struct ClipboardConfig: Codable, Equatable {
    var restorePrevious: Bool
    var restoreDelayMilliseconds: Int
}

struct UpdateConfig: Codable, Equatable {
    var checkAutomatically: Bool
}

enum FlowTypeError: LocalizedError {
    case configuration(String)
    case permission(String)
    case recording(String)
    case conversion(String)
    case transcription(String)
    case cleanup(String)
    case insertion(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message),
             .permission(let message),
             .recording(let message),
             .conversion(let message),
             .transcription(let message),
             .cleanup(let message),
             .insertion(let message):
            return message
        }
    }
}

extension String {
    var expandingTildeInPath: String {
        NSString(string: self).expandingTildeInPath
    }
}
