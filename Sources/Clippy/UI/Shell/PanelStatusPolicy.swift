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
    /// the user acts (failures). A non-failure toast with an inline action
    /// (Undo/View) stays long enough to use it.
    static func autoDismissSeconds(for severity: PanelStatusSeverity, hasAction: Bool) -> TimeInterval? {
        switch severity {
        case .success: return hasAction ? 6 : 3
        case .info: return hasAction ? 6 : 4
        case .warning: return 8
        case .failure: return nil
        }
    }

    /// Persistent messages render as the solid banner, transient ones as the toast.
    static func isPersistent(for severity: PanelStatusSeverity, hasAction: Bool) -> Bool {
        autoDismissSeconds(for: severity, hasAction: hasAction) == nil
    }
}
