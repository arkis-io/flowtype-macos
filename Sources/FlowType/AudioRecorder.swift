import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingDirectory: URL?
    private let writeErrorLock = NSLock()
    private var writeError: Error?
    private(set) var isUsingVoiceProcessing = false
    private(set) var activeInputDeviceName = "System Default"

    var isRecording: Bool {
        engine?.isRunning == true
    }

    func start(config: AudioConfig) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw FlowTypeError.permission("Microphone access is required. Use the menu bar item to request it, then enable FlowType in System Settings → Privacy & Security → Microphone.")
        }
        guard !isRecording else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowType", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("recording.caf")

        writeErrorLock.lock()
        writeError = nil
        writeErrorLock.unlock()

        do {
            let preferredDevice = config.inputDeviceUID == AudioDeviceService.systemDefaultUID
                ? nil
                : AudioDeviceService.inputDevice(withUID: config.inputDeviceUID)
            let voiceModes = config.voiceProcessingEnabled ? [true, false] : [false]
            var attempts = voiceModes.map { (voiceProcessing: $0, deviceID: preferredDevice?.id) }
            if preferredDevice != nil {
                attempts.append(contentsOf: voiceModes.map { (voiceProcessing: $0, deviceID: nil) })
            }

            var setup: (engine: AVAudioEngine, file: AVAudioFile, voiceProcessing: Bool, deviceID: AudioDeviceID?)?
            var lastError: Error?
            for attempt in attempts {
                do {
                    setup = try makeEngine(
                        sourceURL: sourceURL,
                        useVoiceProcessing: attempt.voiceProcessing,
                        duckingLevel: config.duckingLevel,
                        deviceID: attempt.deviceID
                    )
                    break
                } catch {
                    lastError = error
                }
            }
            guard let setup else {
                throw lastError ?? FlowTypeError.recording("FlowType could not start the selected microphone.")
            }

            engine = setup.engine
            audioFile = setup.file
            isUsingVoiceProcessing = setup.voiceProcessing
            activeInputDeviceName = setup.deviceID.flatMap(AudioDeviceService.inputDevice(withID:))?.name
                ?? AudioDeviceService.defaultInputDevice()?.name
                ?? "System Default"
            recordingDirectory = directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() throws -> URL {
        guard let engine, let directory = recordingDirectory else {
            throw FlowTypeError.recording("There is no active recording to stop.")
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isUsingVoiceProcessing = false
        audioFile = nil
        recordingDirectory = nil

        writeErrorLock.lock()
        let capturedWriteError = writeError
        writeError = nil
        writeErrorLock.unlock()

        if let capturedWriteError {
            try? FileManager.default.removeItem(at: directory)
            throw FlowTypeError.recording("Audio recording failed: \(capturedWriteError.localizedDescription)")
        }

        return directory.appendingPathComponent("recording.caf")
    }

    func cancel() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isUsingVoiceProcessing = false
        audioFile = nil

        if let recordingDirectory {
            try? FileManager.default.removeItem(at: recordingDirectory)
        }
        recordingDirectory = nil
    }

    @available(macOS 14.0, *)
    private static func duckingLevel(
        from value: String
    ) -> AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level {
        switch value.lowercased() {
        case "min": return .min
        case "mid": return .mid
        case "max": return .max
        default: return .default
        }
    }

    private func makeEngine(
        sourceURL: URL,
        useVoiceProcessing: Bool,
        duckingLevel: String,
        deviceID: AudioDeviceID?
    ) throws -> (engine: AVAudioEngine, file: AVAudioFile, voiceProcessing: Bool, deviceID: AudioDeviceID?) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if useVoiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: Self.duckingLevel(from: duckingLevel)
                    )
            }
        }

        if var deviceID {
            guard let audioUnit = input.audioUnit else {
                throw FlowTypeError.recording("The selected microphone could not be attached to the audio engine.")
            }
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw FlowTypeError.recording("The selected microphone could not be opened (Core Audio \(status)).")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw FlowTypeError.recording("The selected microphone did not expose a usable audio format.")
        }
        if useVoiceProcessing, format.channelCount > 2 {
            throw FlowTypeError.recording(
                "Voice processing exposed an unsupported multichannel stream; retrying with normal microphone capture."
            )
        }

        let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                self?.writeErrorLock.lock()
                self?.writeError = error
                self?.writeErrorLock.unlock()
            }
        }

        do {
            engine.prepare()
            try engine.start()
            return (engine, file, useVoiceProcessing, deviceID)
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }
}

final class AudioConverterService {
    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func convertToWhisperWAV(_ sourceURL: URL) async throws -> URL {
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
}
