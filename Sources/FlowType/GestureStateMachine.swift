import Foundation

struct GestureStateMachine {
    private static let timerTolerance: TimeInterval = 0.000_001

    enum Phase: Equatable {
        case idle
        case holding(startedAt: TimeInterval)
        case waitingForSecondTap(startedAt: TimeInterval, deadline: TimeInterval)
        case handsFree(startedAt: TimeInterval)
        case processing
    }

    enum Event: Equatable {
        case hotkeyDown(at: TimeInterval)
        case hotkeyUp(at: TimeInterval)
        case toggleHotkeyDown(at: TimeInterval)
        case doubleTapWindowExpired(at: TimeInterval)
        case autoStop
        case escape
        case beginExternalProcessing
        case processingFinished
    }

    enum Action: Equatable {
        case startRecording
        case showHeldMode
        case showHandsFreeMode
        case scheduleDoubleTapExpiry(after: TimeInterval)
        case cancelDoubleTapExpiry
        case stopAndProcess
        case cancel
        case hide
    }

    private(set) var phase: Phase = .idle

    mutating func handle(_ event: Event, config: GestureConfig) -> [Action] {
        switch (phase, event) {
        case (.idle, .hotkeyDown(let now)):
            phase = .holding(startedAt: now)
            return [.startRecording, .showHeldMode]

        case (.idle, .toggleHotkeyDown(let now)):
            phase = .handsFree(startedAt: now)
            return [.startRecording, .showHandsFreeMode]

        case (.holding(let startedAt), .hotkeyUp(let now)):
            let heldDuration = max(0, now - startedAt)
            if heldDuration <= config.quickTapMaxDuration {
                if config.hybridPrimaryHotkey {
                    phase = .handsFree(startedAt: startedAt)
                    return [.showHandsFreeMode]
                }
                phase = .waitingForSecondTap(
                    startedAt: startedAt,
                    deadline: now + config.doubleTapInterval
                )
                return [.scheduleDoubleTapExpiry(after: config.doubleTapInterval)]
            }
            phase = .processing
            return [.stopAndProcess]

        case (.waitingForSecondTap(let startedAt, let deadline), .hotkeyDown(let now)) where now <= deadline + Self.timerTolerance:
            phase = .handsFree(startedAt: startedAt)
            return [.cancelDoubleTapExpiry, .showHandsFreeMode]

        case (.waitingForSecondTap(let startedAt, _), .toggleHotkeyDown):
            phase = .handsFree(startedAt: startedAt)
            return [.cancelDoubleTapExpiry, .showHandsFreeMode]

        case (.waitingForSecondTap(_, let deadline), .doubleTapWindowExpired(let now)) where now >= deadline - Self.timerTolerance:
            phase = .processing
            return [.stopAndProcess]

        case (.handsFree, .hotkeyDown):
            phase = .processing
            return [.stopAndProcess]

        case (.handsFree, .toggleHotkeyDown):
            phase = .processing
            return [.stopAndProcess]

        case (.holding, .autoStop), (.waitingForSecondTap, .autoStop), (.handsFree, .autoStop):
            phase = .processing
            return [.cancelDoubleTapExpiry, .stopAndProcess]

        case (.holding, .escape), (.waitingForSecondTap, .escape), (.handsFree, .escape), (.processing, .escape):
            phase = .idle
            return [.cancelDoubleTapExpiry, .cancel, .hide]

        case (.processing, .processingFinished):
            phase = .idle
            return [.hide]

        case (.idle, .beginExternalProcessing):
            phase = .processing
            return []

        default:
            return []
        }
    }

    mutating func reset() {
        phase = .idle
    }
}
