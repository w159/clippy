import Foundation
import ServiceManagement

/// Launch-at-login control backed by `SMAppService.mainApp`. Status is always
/// read from the system, never cached, so a change made in System Settings
/// is reflected the next time it is read.
enum LaunchAtLogin {
    /// Registration state of the main-app login item.
    enum Status: Equatable {
        case enabled
        /// Not registered.
        case disabled
        /// Registered but the user must approve it in System Settings > Login Items.
        case requiresApproval
        /// The service could not be found (unbundled build).
        case notFound
    }

    /// Current system status.
    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Registers or unregisters the login item; throws the ServiceManagement error.
    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    /// Opens System Settings > General > Login Items.
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
