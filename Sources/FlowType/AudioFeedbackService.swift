import AppKit

@MainActor
final class AudioFeedbackService {
    private let boundarySound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)

    init() {
        boundarySound?.volume = 0.32
    }

    func playStarted(ifEnabled enabled: Bool) {
        guard enabled else { return }
        boundarySound?.stop()
        boundarySound?.play()
    }

    func playStopped(ifEnabled enabled: Bool) {
        guard enabled else { return }
        boundarySound?.stop()
        boundarySound?.play()
    }
}
