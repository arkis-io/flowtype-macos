import AVFoundation
import Foundation

@main
struct AudioCaptureProbe {
    static func main() async {
        let requestedUID = CommandLine.arguments.dropFirst().first ?? AudioDeviceService.systemDefaultUID
        if requestedUID == "list" {
            for device in AudioDeviceService.inputDevices() {
                print("\(device.uid)\t\(device.name)\tbluetooth=\(device.isBluetooth)\tbuiltIn=\(device.isBuiltIn)")
            }
            return
        }
        if requestedUID == "boost-fixture" {
            await runBoostFixture()
            return
        }

        var config = AppConfig.defaultConfig.audio
        config.inputDeviceUID = requestedUID
        config.inputDeviceName = AudioDeviceService.inputDevice(withUID: requestedUID)?.name ?? ""
        let recorder = AudioRecorder()

        do {
            try recorder.start(config: config)
            print("CAPTURE_DEVICE=\(recorder.activeInputDeviceName)")
            if !recorder.activeInputRoutingNote.isEmpty {
                print("CAPTURE_ROUTE=\(recorder.activeInputRoutingNote)")
            }

            var maximumLevel: Float = 0
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                maximumLevel = max(maximumLevel, recorder.normalizedInputLevel)
            }
            let sourceURL = try await recorder.stop()
            let file = try AVAudioFile(forReading: sourceURL)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            let size = ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            print("MAX_LEVEL=\(String(format: "%.3f", maximumLevel))")
            print("DURATION_SECONDS=\(String(format: "%.3f", duration))")
            print("CAPTURE_BYTES=\(size)")
            print("CAPTURE_RESULT=passed")
            if ProcessInfo.processInfo.environment["FLOWTYPE_KEEP_CAPTURE"] == "1" {
                print("CAPTURE_PATH=\(sourceURL.path)")
            } else {
                try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            }
        } catch {
            recorder.cancel()
            print("CAPTURE_RESULT=failed")
            print("CAPTURE_ERROR=\(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    private static func runBoostFixture() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTypeBoostProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("quiet.caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            let frameCount: AVAudioFrameCount = 16_000
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            let samples = buffer.floatChannelData![0]
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.04) * 0.01
            }
            try file.write(from: buffer)

            let outputURL = try await AudioConverterService().convertToWhisperWAV(
                sourceURL,
                boostQuietSpeech: true
            )
            let output = try AVAudioFile(forReading: outputURL)
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: output.processingFormat,
                frameCapacity: AVAudioFrameCount(output.length)
            )!
            try output.read(into: outputBuffer)
            let outputSamples = outputBuffer.floatChannelData![0]
            var peak: Float = 0
            for frame in 0..<Int(outputBuffer.frameLength) {
                peak = max(peak, abs(outputSamples[frame]))
            }
            print("BOOSTED_PEAK=\(String(format: "%.3f", peak))")
            guard peak >= 0.035, peak <= 0.05 else {
                throw FlowTypeError.conversion("Quiet-speech gain produced an unexpected peak.")
            }
            print("BOOST_RESULT=passed")
        } catch {
            print("BOOST_RESULT=failed")
            print("BOOST_ERROR=\(error.localizedDescription)")
            Foundation.exit(1)
        }
    }
}
