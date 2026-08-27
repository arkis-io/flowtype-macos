import CoreGraphics
import Foundation

final class GlobalEventMonitor {
    var onHotkeyDown: ((TimeInterval) -> Void)?
    var onHotkeyUp: ((TimeInterval) -> Void)?
    var onToggleHotkeyDown: ((TimeInterval) -> Void)?
    var onEscape: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pushToTalkHotkey: HotkeyDefinition
    private var toggleHotkey: HotkeyDefinition
    private var pushToTalkIsDown = false
    private var toggleIsDown = false

    init(config: HotkeyConfig, toggleConfig: HotkeyConfig) throws {
        pushToTalkHotkey = try HotkeyDefinition(config: config)
        toggleHotkey = try HotkeyDefinition(config: toggleConfig)
    }

    func update(config: HotkeyConfig, toggleConfig: HotkeyConfig) throws {
        pushToTalkHotkey = try HotkeyDefinition(config: config)
        toggleHotkey = try HotkeyDefinition(config: toggleConfig)
        pushToTalkIsDown = false
        toggleIsDown = false
    }

    func install() throws {
        uninstall()

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw FlowTypeError.permission("Input Monitoring is required for the global hotkeys. Enable FlowType in System Settings → Privacy & Security → Input Monitoring, then reload configuration.")
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        runLoopSource = source
    }

    func uninstall() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        pushToTalkIsDown = false
        toggleIsDown = false
    }

    private func handle(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        if eventType == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == HotkeyDefinition.escapeKeyCode {
                onEscape?()
            }
        }

        // CGEvent timestamps are captured when the physical event occurs. Keep
        // that source time so microphone startup cannot make a quick tap look
        // like a long hold while the main run loop is busy.
        let eventTime = event.timestamp > 0
            ? TimeInterval(event.timestamp) / 1_000_000_000
            : ProcessInfo.processInfo.systemUptime

        let pushResult = pushToTalkHotkey.transition(
            eventType: eventType,
            event: event,
            wasDown: pushToTalkIsDown
        )
        pushToTalkIsDown = pushResult.isDown
        switch pushResult.transition {
        case .down: onHotkeyDown?(eventTime)
        case .up: onHotkeyUp?(eventTime)
        case nil: break
        }

        let toggleResult = toggleHotkey.transition(
            eventType: eventType,
            event: event,
            wasDown: toggleIsDown
        )
        toggleIsDown = toggleResult.isDown
        if toggleResult.transition == .down {
            onToggleHotkeyDown?(eventTime)
        }
    }
}

private enum ShortcutTransition: Equatable {
    case down
    case up
}

private struct HotkeyDefinition {
    enum Kind {
        case functionKey
        case standaloneModifier(keyCode: Int, sideMask: CGEventFlags)
        case keyCode(Int, CGEventFlags)
    }

    static let escapeKeyCode = 0x35
    static let relevantModifierMask: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn
    ]

    let kind: Kind

    init(config: HotkeyConfig) throws {
        try SettingsValidator.validateHotkey(config)
        let key = config.key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "fn" || key == "function" || key == "globe" {
            kind = .functionKey
            return
        }

        // Key codes come from Carbon/HIToolbox Events.h. Side masks come from
        // IOKit hidsystem/IOLLEvent.h and distinguish left/right modifier state.
        switch key {
        case "right_command": kind = .standaloneModifier(keyCode: 0x36, sideMask: CGEventFlags(rawValue: 0x00000010))
        case "right_shift": kind = .standaloneModifier(keyCode: 0x3C, sideMask: CGEventFlags(rawValue: 0x00000004))
        case "right_option": kind = .standaloneModifier(keyCode: 0x3D, sideMask: CGEventFlags(rawValue: 0x00000040))
        case "right_control": kind = .standaloneModifier(keyCode: 0x3E, sideMask: CGEventFlags(rawValue: 0x00002000))
        default:
            guard let keyCode = Self.keyCodes[key] else {
                throw FlowTypeError.configuration("Unknown hotkey key '\(config.key)'.")
            }
            guard keyCode != Self.escapeKeyCode else {
                throw FlowTypeError.configuration("Escape is reserved for cancelling dictation.")
            }
            kind = .keyCode(keyCode, try Self.modifierFlags(from: config.modifiers))
        }
    }

    func transition(
        eventType: CGEventType,
        event: CGEvent,
        wasDown: Bool
    ) -> (isDown: Bool, transition: ShortcutTransition?) {
        switch kind {
        case .functionKey:
            guard eventType == .flagsChanged else { return (wasDown, nil) }
            return transition(from: wasDown, to: event.flags.contains(.maskSecondaryFn))

        case .standaloneModifier(let expectedKeyCode, let sideMask):
            guard eventType == .flagsChanged,
                  Int(event.getIntegerValueField(.keyboardEventKeycode)) == expectedKeyCode else {
                return (wasDown, nil)
            }
            return transition(from: wasDown, to: event.flags.contains(sideMask))

        case .keyCode(let expectedKeyCode, let requiredModifiers):
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == expectedKeyCode else { return (wasDown, nil) }

            if eventType == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard !isRepeat, !wasDown else { return (wasDown, nil) }
                let activeModifiers = event.flags.intersection(Self.relevantModifierMask)
                guard activeModifiers == requiredModifiers else { return (wasDown, nil) }
                return (true, .down)
            }
            if eventType == .keyUp, wasDown {
                return (false, .up)
            }
            return (wasDown, nil)
        }
    }

    private func transition(
        from wasDown: Bool,
        to isDown: Bool
    ) -> (isDown: Bool, transition: ShortcutTransition?) {
        guard isDown != wasDown else { return (wasDown, nil) }
        return (isDown, isDown ? .down : .up)
    }

    private static func modifierFlags(from modifiers: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd": flags.insert(.maskCommand)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn", "function", "globe": flags.insert(.maskSecondaryFn)
            default:
                throw FlowTypeError.configuration("Unknown hotkey modifier '\(modifier)'.")
            }
        }
        return flags
    }

    private static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
