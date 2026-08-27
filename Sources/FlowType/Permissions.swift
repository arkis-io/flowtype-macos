import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

enum Permissions {
    static var canRecordAudio: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var canMonitorInput: Bool {
        CGPreflightListenEventAccess()
    }

    static var canInsertText: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }
}
