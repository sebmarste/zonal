import AppKit
import ApplicationServices
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case registrationMissing
    case unavailable

    var isRequested: Bool {
        switch self {
        case .enabled, .requiresApproval:
            true
        case .disabled, .registrationMissing, .unavailable:
            false
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            "Start Zonal automatically when you sign in."
        case .enabled:
            "Zonal starts automatically when you sign in."
        case .requiresApproval:
            "Allow Zonal under Login Items in System Settings to finish enabling this."
        case .registrationMissing:
            "Launch at login is unavailable. Keep Zonal in Applications and retry Launch at Login."
        case .unavailable:
            "Launch at login is unavailable for this copy of Zonal."
        }
    }
}

protocol LaunchAtLoginServicing {
    var state: LaunchAtLoginState { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

extension LaunchAtLoginServicing {
    func setEnabled(_ enabled: Bool) throws {
        if enabled, !state.isRequested { try register() }
        else if !enabled, state.isRequested { try unregister() }
    }
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private var service: SMAppService { .mainApp }

    var state: LaunchAtLoginState {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .registrationMissing
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class PermissionsController {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var canListenForInputEvents: Bool {
        CGPreflightListenEventAccess() || isAccessibilityTrusted
    }

    var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    func requestAccessibilityTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
