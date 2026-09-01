import AudioToolbox
import CoreAudio
import Foundation

func defaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
}

func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    return status == noErr ? value as String : nil
}

func inspect(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector,
    element: AudioObjectPropertyElement,
    label: String
) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: element
    )
    let exists = AudioObjectHasProperty(deviceID, &address)
    var settable: DarwinBoolean = false
    let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
    var value = Float32.zero
    var size = UInt32(MemoryLayout<Float32>.size)
    let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    print(
        "\(label): exists=\(exists) settable=\(settableStatus == noErr && settable.boolValue) "
            + "readStatus=\(readStatus) value=\(readStatus == noErr ? String(value) : "n/a")"
    )
}

guard let deviceID = defaultOutputDeviceID() else {
    fputs("No default output device\n", stderr)
    exit(1)
}

print("device=\(stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Unknown")")
print("uid=\(stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown")")

inspect(
    deviceID: deviceID,
    selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    element: kAudioObjectPropertyElementMain,
    label: "virtual-main"
)

for element in 0 ... 8 {
    inspect(
        deviceID: deviceID,
        selector: kAudioDevicePropertyVolumeScalar,
        element: AudioObjectPropertyElement(element),
        label: "scalar-element-\(element)"
    )
}

if CommandLine.arguments.contains("--cycle") {
    let backend = CoreAudioOutputVolumeController()
    guard let control = backend.defaultOutputControl(),
          let originalVolume = backend.volume(for: control) else {
        fputs("The default output does not expose a writable virtual main volume\n", stderr)
        exit(2)
    }

    let recoveryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowTypeOutputVolumeProbe-\(UUID().uuidString).json")
    let ducker = OutputVolumeDucker(recoveryURL: recoveryURL, backend: backend)
    guard ducker.begin(enabled: true, level: "max"),
          let loweredVolume = backend.volume(for: control) else {
        fputs("Unable to lower and verify the default output volume\n", stderr)
        exit(3)
    }

    print("cycle-original=\(originalVolume)")
    print("cycle-lowered=\(loweredVolume)")
    Thread.sleep(forTimeInterval: 1.0)

    guard ducker.restoreIfNeeded(),
          let restoredVolume = backend.volume(for: control) else {
        fputs("Unable to restore the default output volume\n", stderr)
        exit(4)
    }
    print("cycle-restored=\(restoredVolume)")
}
