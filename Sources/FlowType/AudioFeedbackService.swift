import AppKit

@MainActor
final class AudioFeedbackService {
    private let startSound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    private let stopSound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)

    init() {
        startSound?.volume = 0.32
        stopSound?.volume = 0.32
    }

    func playStarted(ifEnabled enabled: Bool) {
        guard enabled else { return }
        stopSound?.stop()
        startSound?.stop()
        startSound?.play()
    }

    func playStopped(ifEnabled enabled: Bool) {
        guard enabled else { return }
        startSound?.stop()
        stopSound?.stop()
        stopSound?.play()
    }
}
