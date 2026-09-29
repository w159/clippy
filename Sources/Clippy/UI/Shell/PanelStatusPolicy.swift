import Foundation

/// Severity of a panel status message as raised by `ClipListView` callers.
/// Maps onto the design-system `BannerSeverity` for rendering.
enum PanelStatusSeverity: Equatable {
    case info, success, warning, failure

    /// Design-system severity used for styling.
    var banner: BannerSeverity {
        switch self {
        case .info: return .neutral
        case .success: return .success
        case .warning: return .warning
        case .failure: return .danger
        }
    }
}

/// Pure timing and presentation policy for panel status messages.
enum PanelStatusPolicy {
    /// Seconds before a message dismisses itself; nil when it must stay until
    /// the user acts (failures, and anything that carries an action).
    static func autoDismissSeconds(for severity: PanelStatusSeverity, hasAction: Bool) -> TimeInterval? {
        if hasAction { return nil }
        switch severity {
        case .success: return 3
        case .info: return 4
        case .warning: return 8
        case .failure: return nil
        }
    }

    /// Persistent messages render as the solid banner, transient ones as the toast.
    static func isPersistent(for severity: PanelStatusSeverity, hasAction: Bool) -> Bool {
        autoDismissSeconds(for: severity, hasAction: hasAction) == nil
    }
}
