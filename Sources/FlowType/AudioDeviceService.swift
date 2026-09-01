import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

struct AudioCapturePlan: Equatable {
    enum Reason: Equatable {
        case systemDefault
        case explicitlySelected
        case avoidedBluetoothHeadsetMic
    }

    let input: AudioInputDevice
    let reason: Reason
}

enum AudioDeviceService {
    static let systemDefaultUID = "system_default"

    static func inputDevices() -> [AudioInputDevice] {
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
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName),
                  let transportType = uint32Property(deviceID, selector: kAudioDevicePropertyTransportType) else {
                return nil
            }
            return AudioInputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                transportType: transportType
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else { return nil }
        return inputDevices().first { $0.id == deviceID }
    }

    static func inputDevice(withUID uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    static func inputDevice(withID id: AudioDeviceID) -> AudioInputDevice? {
        inputDevices().first { $0.id == id }
    }

    static func defaultOutputDevice() -> AudioOutputDevice? {
        guard let deviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice),
              let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, selector: kAudioObjectPropertyName),
              let transportType = uint32Property(deviceID, selector: kAudioDevicePropertyTransportType) else {
            return nil
        }
        return AudioOutputDevice(
            id: deviceID,
            uid: uid,
            name: name,
            transportType: transportType
        )
    }

    static func capturePlan(for config: AudioConfig) throws -> AudioCapturePlan {
        let devices = inputDevices()
        if config.inputDeviceUID != systemDefaultUID {
            guard let selected = devices.first(where: { $0.uid == config.inputDeviceUID }) else {
                let label = config.inputDeviceName.isEmpty ? "The selected microphone" : config.inputDeviceName
                throw FlowTypeError.recording(
                    "\(label) is unavailable. Reconnect it or choose Automatic in FlowType Settings."
                )
            }
            return AudioCapturePlan(input: selected, reason: .explicitlySelected)
        }

        guard let defaultInput = defaultInputDevice() else {
            throw FlowTypeError.recording("macOS did not provide an available microphone.")
        }
        let preferred = preferredAutomaticInput(
            defaultInput: defaultInput,
            availableInputs: devices,
            bluetoothOutputActive: defaultOutputDevice()?.isBluetooth == true,
            avoidBluetoothHeadsetMic: config.preferBuiltInMicWithBluetoothOutput
        )
        return AudioCapturePlan(
            input: preferred,
            reason: preferred.id == defaultInput.id ? .systemDefault : .avoidedBluetoothHeadsetMic
        )
    }

    static func preferredAutomaticInput(
        defaultInput: AudioInputDevice,
        availableInputs: [AudioInputDevice],
        bluetoothOutputActive: Bool,
        avoidBluetoothHeadsetMic: Bool
    ) -> AudioInputDevice {
        guard avoidBluetoothHeadsetMic,
              bluetoothOutputActive,
              defaultInput.isBluetooth,
              let builtIn = availableInputs.first(where: \.isBuiltIn) else {
            return defaultInput
        }
        return builtIn
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr
            && dataSize > 0
    }

    private static func stringProperty(
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

    private static func uint32Property(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
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

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
