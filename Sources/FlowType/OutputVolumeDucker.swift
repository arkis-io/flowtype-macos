import AudioToolbox
import CoreAudio
import Foundation

struct OutputVolumeControl: Codable, Equatable {
    let deviceUID: String
    let deviceName: String
    let element: UInt32
}

protocol OutputVolumeControlling: AnyObject {
    func defaultOutputControl() -> OutputVolumeControl?
    func volume(for control: OutputVolumeControl) -> Float32?
    func setVolume(_ volume: Float32, for control: OutputVolumeControl) -> Bool
}

enum OutputDuckingLevel {
    static func multiplier(for value: String) -> Float32 {
        switch value.lowercased() {
        case "min": return 0.65
        case "max": return 0.15
        case "mid", "default": return 0.35
        default: return 0.35
        }
    }
}

final class OutputVolumeDucker {
    private struct RecoveryState: Codable, Equatable {
        let control: OutputVolumeControl
        let originalVolume: Float32
    }

    private let backend: OutputVolumeControlling
    private let recoveryURL: URL
    private let fileManager: FileManager
    private var activeState: RecoveryState?

    private(set) var isDucking = false
    private(set) var activeDeviceName: String?

    init(
        recoveryURL: URL,
        backend: OutputVolumeControlling = CoreAudioOutputVolumeController(),
        fileManager: FileManager = .default
    ) {
        self.recoveryURL = recoveryURL
        self.backend = backend
        self.fileManager = fileManager
    }

    @discardableResult
    func begin(enabled: Bool, level: String) -> Bool {
        guard enabled else { return false }
        if isDucking { return true }

        // Never stack a new volume change on top of an unrestored session.
        if fileManager.fileExists(atPath: recoveryURL.path), !restoreIfNeeded() {
            return false
        }

        guard let control = backend.defaultOutputControl(),
              let originalVolume = backend.volume(for: control) else {
            return false
        }

        let targetVolume = max(0, min(1, originalVolume * OutputDuckingLevel.multiplier(for: level)))
        guard targetVolume < originalVolume else { return false }

        let state = RecoveryState(control: control, originalVolume: originalVolume)
        do {
            try fileManager.createDirectory(
                at: recoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: recoveryURL, options: .atomic)
        } catch {
            return false
        }

        guard backend.setVolume(targetVolume, for: control) else {
            try? fileManager.removeItem(at: recoveryURL)
            return false
        }

        activeState = state
        isDucking = true
        activeDeviceName = control.deviceName
        return true
    }

    @discardableResult
    func restoreIfNeeded() -> Bool {
        let state: RecoveryState
        if let activeState {
            state = activeState
        } else {
            guard let data = try? Data(contentsOf: recoveryURL),
                  let persisted = try? JSONDecoder().decode(RecoveryState.self, from: data) else {
                isDucking = false
                activeDeviceName = nil
                return !fileManager.fileExists(atPath: recoveryURL.path)
            }
            state = persisted
        }

        guard backend.setVolume(state.originalVolume, for: state.control) else {
            return false
        }

        try? fileManager.removeItem(at: recoveryURL)
        activeState = nil
        isDucking = false
        activeDeviceName = nil
        return true
    }
}

final class CoreAudioOutputVolumeController: OutputVolumeControlling {
    func defaultOutputControl() -> OutputVolumeControl? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return virtualMainVolumeControl(for: deviceID)
    }

    func volume(for control: OutputVolumeControl) -> Float32? {
        guard let deviceID = deviceID(withUID: control.deviceUID) else { return nil }
        var address = virtualMainVolumeAddress()
        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr ? value : nil
    }

    func setVolume(_ volume: Float32, for control: OutputVolumeControl) -> Bool {
        guard let deviceID = deviceID(withUID: control.deviceUID) else { return false }
        var address = virtualMainVolumeAddress()
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var clampedVolume = max(0, min(1, volume))
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &clampedVolume
        )
        guard status == noErr else { return false }

        var readback = Float32.zero
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &readback
        ) == noErr else {
            return false
        }

        return abs(readback - clampedVolume) <= 0.02
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func deviceID(withUID uid: String) -> AudioDeviceID? {
        for deviceID in allDeviceIDs() {
            if stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
                return deviceID
            }
        }
        return nil
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        return status == noErr ? deviceIDs : []
    }

    private func virtualMainVolumeControl(for deviceID: AudioDeviceID) -> OutputVolumeControl? {
        var address = virtualMainVolumeAddress()
        var isSettable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue,
              let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }

        return OutputVolumeControl(
            deviceUID: uid,
            deviceName: stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Current output",
            // Retained in the recovery schema for compatibility with older builds.
            element: kAudioObjectPropertyElementMain
        )
    }

    private func virtualMainVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        return status == noErr ? value as String : nil
    }
}
