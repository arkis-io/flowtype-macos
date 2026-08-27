import Foundation

enum PermissionSetupStep: String, Equatable {
    case microphone
    case inputMonitoring
    case accessibility
    case ready

    static func next(
        microphoneAllowed: Bool,
        inputMonitoringAllowed: Bool,
        accessibilityAllowed: Bool
    ) -> PermissionSetupStep {
        if !microphoneAllowed { return .microphone }
        if !inputMonitoringAllowed { return .inputMonitoring }
        if !accessibilityAllowed { return .accessibility }
        return .ready
    }

    var buttonTitle: String {
        switch self {
        case .microphone: return "1 of 3 — Allow Microphone"
        case .inputMonitoring: return "2 of 3 — Allow Input Monitoring"
        case .accessibility: return "3 of 3 — Allow Accessibility"
        case .ready: return "Permissions Ready"
        }
    }

    var settingsButtonTitle: String {
        switch self {
        case .microphone: return "Open Microphone Settings"
        case .inputMonitoring: return "Open Input Monitoring Settings"
        case .accessibility: return "Open Accessibility Settings"
        case .ready: return ""
        }
    }

    var settingsAnchor: String? {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .accessibility: return "Privacy_Accessibility"
        case .ready: return nil
        }
    }
}
