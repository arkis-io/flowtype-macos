import AVFoundation
import AudioToolbox
import Foundation

// AVCaptureSession owns an explicit AVCaptureDeviceInput. Unlike retargeting an
// AVAudioEngine audio unit after it has been created, this guarantees that the
// device shown in the UI is the device feeding the recording.
final class AudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var captureSession: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var recordingDirectory: URL?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var finalizedResult: Result<URL, Error>?
    private var cancellationRequested = false
    private var deleteOnCancellation = true
    private var usesDurableDirectory = false

    private(set) var activeInputDeviceName = "System Default"
    private(set) var activeInputRoutingNote = ""

    var isRecording: Bool {
        captureSession != nil && finalizedResult == nil && !cancellationRequested
    }

    var normalizedInputLevel: Float {
        let decibels = fileOutput?.connections
            .flatMap(\.audioChannels)
            .map(\.averagePowerLevel)
            .max() ?? -60
        return min(max((decibels + 60) / 60, 0), 1)
    }

    func start(config: AudioConfig, destinationDirectory: URL? = nil) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw FlowTypeError.permission("Microphone access is required. Use the menu bar item to request it, then enable FlowType in System Settings → Privacy & Security → Microphone.")
        }
        guard !isRecording else { return }

        let directory = destinationDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowType", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("recording.caf")

        do {
            let plan = try AudioDeviceService.capturePlan(for: config)
            guard let captureDevice = AVCaptureDevice(uniqueID: plan.input.uid) else {
                throw FlowTypeError.recording(
                    "\(plan.input.name) could not be opened by the macOS capture system."
                )
            }
            let input = try AVCaptureDeviceInput(device: captureDevice)
            let output = AVCaptureAudioFileOutput()
            guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.caf) else {
                throw FlowTypeError.recording("This Mac cannot create the temporary audio format FlowType needs.")
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw FlowTypeError.recording("\(plan.input.name) could not be connected for recording.")
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw FlowTypeError.recording("FlowType could not connect its audio recorder.")
            }
            session.addOutput(output)
            session.commitConfiguration()

            cancellationRequested = false
            deleteOnCancellation = true
            finalizedResult = nil
            stopContinuation = nil
            captureSession = session
            fileOutput = output
            recordingDirectory = directory
            recordingURL = sourceURL
            usesDurableDirectory = destinationDirectory != nil
            activeInputDeviceName = plan.input.name
            activeInputRoutingNote = plan.reason == .avoidedBluetoothHeadsetMic
                ? "Using the built-in microphone so Bluetooth music stays clear."
                : ""

            session.startRunning()
            guard session.isRunning else {
                throw FlowTypeError.recording("The macOS capture session did not start.")
            }
            output.startRecording(to: sourceURL, outputFileType: .caf, recordingDelegate: self)
        } catch {
            tearDownCapture(deleteRecording: true)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() async throws -> URL {
        if let result = finalizedResult {
            finalizedResult = nil
            return try result.get()
        }
        guard let output = fileOutput, recordingURL != nil else {
            throw FlowTypeError.recording("There is no active recording to stop.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            requestStopWhenReady(output: output, attemptsRemaining: 20)
        }
    }

    func cancel(retainRecording: Bool = false) {
        cancellationRequested = true
        deleteOnCancellation = !retainRecording
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume(throwing: CancellationError())
        }

        guard let output = fileOutput, output.isRecording else {
            tearDownCapture(deleteRecording: deleteOnCancellation)
            return
        }
        output.stopRecording()
    }

    func duration(of audioURL: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: audioURL),
              file.processingFormat.sampleRate > 0 else { return 0 }
        return TimeInterval(file.length) / file.processingFormat.sampleRate
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.finishRecording(outputFileURL: outputFileURL, error: error)
        }
    }

    private func requestStopWhenReady(
        output: AVCaptureAudioFileOutput,
        attemptsRemaining: Int
    ) {
        guard stopContinuation != nil else { return }
        if output.isRecording {
            output.stopRecording()
            return
        }
        guard attemptsRemaining > 0, captureSession?.isRunning == true else {
            let error = FlowTypeError.recording(
                "The microphone opened but did not begin delivering audio. Try the microphone test in Settings."
            )
            let continuation = stopContinuation
            stopContinuation = nil
            tearDownCapture(deleteRecording: true)
            continuation?.resume(throwing: error)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak output] in
            guard let self, let output else { return }
            self.requestStopWhenReady(output: output, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func finishRecording(outputFileURL: URL, error: Error?) {
        let wasCancelled = cancellationRequested
        let successfullyFinished: Bool
        if let error = error as NSError? {
            successfullyFinished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        } else {
            successfullyFinished = true
        }

        let result: Result<URL, Error>
        if wasCancelled {
            result = .failure(CancellationError())
        } else if successfullyFinished {
            result = .success(outputFileURL)
        } else {
            result = .failure(
                FlowTypeError.recording(
                    "Audio recording ended unexpectedly: \(error?.localizedDescription ?? "unknown capture error")"
                )
            )
        }

        let continuation = stopContinuation
        stopContinuation = nil
        if successfullyFinished && usesDurableDirectory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputFileURL.path
            )
        }
        tearDownCapture(deleteRecording: (wasCancelled && deleteOnCancellation) || !successfullyFinished)
        cancellationRequested = false
        deleteOnCancellation = true
        if let continuation {
            continuation.resume(with: result)
        } else if !wasCancelled {
            finalizedResult = result
        }
    }

    private func tearDownCapture(deleteRecording: Bool) {
        if captureSession?.isRunning == true {
            captureSession?.stopRunning()
        }
        captureSession = nil
        fileOutput = nil
        if deleteRecording, let recordingDirectory {
            try? FileManager.default.removeItem(at: recordingDirectory)
        }
        recordingDirectory = nil
        recordingURL = nil
        usesDurableDirectory = false
        activeInputRoutingNote = ""
    }
}

final class AudioConverterService {
    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func convertToWhisperWAV(
        _ sourceURL: URL,
        boostQuietSpeech: Bool = false
    ) async throws -> URL {
        guard let sourceFile = try? AVAudioFile(forReading: sourceURL), sourceFile.length > 0 else {
            throw FlowTypeError.recording(
                "No microphone audio was captured. Try again and begin speaking after the start sound."
            )
        }

        let outputURL = sourceURL.deletingLastPathComponent().appendingPathComponent("recording.wav")
        let result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: [
                sourceURL.path,
                outputURL.path,
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1"
            ]
        )

        try Task.checkCancellation()
        guard result.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            let details = String(data: result.standardError, encoding: .utf8) ?? "Unknown conversion error"
            throw FlowTypeError.conversion("Could not convert the microphone recording to WAV: \(details.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let outputFile = try? AVAudioFile(forReading: outputURL), outputFile.length > 0 else {
            throw FlowTypeError.recording(
                "The microphone recording contained no audio frames. Try again and begin speaking after the start sound."
            )
        }
        let peakAmplitude = try peakAmplitude(in: outputFile)
        guard !AudioSignalQuality.isNearSilent(peakAmplitude: peakAmplitude) else {
            throw FlowTypeError.recording(
                "The microphone recording was nearly silent, so FlowType stopped before transcription. Check the selected microphone and try again."
            )
        }
        if boostQuietSpeech {
            let gain = AudioSignalQuality.gainForQuietSpeech(peakAmplitude: peakAmplitude)
            if gain > 1 {
                return try boostedCopy(of: outputURL, gain: gain)
            }
        }
        return outputURL
    }

    private func peakAmplitude(in file: AVAudioFile) throws -> Float {
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw FlowTypeError.conversion("FlowType could not inspect the recorded audio signal.")
        }

        var peak: Float = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requestedFrames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try file.read(into: buffer, frameCount: requestedFrames)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }

            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(samples[frame]))
                }
            }
        }
        return peak
    }

    private func boostedCopy(of sourceURL: URL, gain: Float) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw FlowTypeError.conversion("FlowType could not boost the captured voice safely.")
        }

        let boostedURL = sourceURL.deletingLastPathComponent().appendingPathComponent("recording-boosted.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let destination = try AVAudioFile(
            forWriting: boostedURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let requestedFrames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try source.read(into: buffer, frameCount: requestedFrames)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = min(max(samples[frame] * gain, -1), 1)
            }
            try destination.write(from: buffer)
        }
        return boostedURL
    }
}
