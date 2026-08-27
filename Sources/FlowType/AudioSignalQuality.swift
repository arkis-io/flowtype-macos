import Foundation

enum AudioSignalQuality {
    // The failed voice-processing stream measured about -91 dBFS. This threshold
    // only rejects effectively empty capture pipelines; it is intentionally far
    // below ordinary quiet speech so it does not act as a speech detector.
    static let minimumPeakAmplitude: Float = 0.00018

    static func isNearSilent(peakAmplitude: Float) -> Bool {
        !peakAmplitude.isFinite || abs(peakAmplitude) < minimumPeakAmplitude
    }
}
