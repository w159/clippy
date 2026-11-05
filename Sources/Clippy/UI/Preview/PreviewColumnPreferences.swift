import CoreGraphics
import Foundation

/// Persisted state of the optional preview column (LAY-11).
/// UserDefaults keys: `preview.column.enabled` (Bool, default true) and `preview.column.width` (Double, default 260).
enum PreviewColumnPreferences {
    /// Narrowest column.
    static let minWidth: CGFloat = 220
    /// Widest column.
    static let maxWidth: CGFloat = 520
    /// Default column width.
    static let defaultWidth: CGFloat = 260
    /// Panel width from which the column may appear.
    static let minPanelWidth: CGFloat = 760
    /// The column is on until the user turns it off.
    static let defaultEnabled = true
    /// Defaults key: column on/off.
    static let enabledKey = "preview.column.enabled"
    /// Defaults key: column width.
    static let widthKey = "preview.column.width"

    /// Clamps a width into the allowed range; NaN falls back to the default.
    static func clamp(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(maxWidth, max(minWidth, width))
    }

    /// True when the column should be shown for this panel width.
    static func isVisible(panelWidth: CGFloat, enabled: Bool) -> Bool {
        enabled && panelWidth >= minPanelWidth
    }

    /// Whether the column is on (default on).
    /// On unless the user turned it off: an absent key counts as enabled.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }

    /// Sets the column on/off.
    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) { defaults.set(value, forKey: enabledKey) }

    /// The stored width, clamped.
    static func width(_ defaults: UserDefaults = .standard) -> CGFloat {
        defaults.object(forKey: widthKey) == nil ? defaultWidth : clamp(CGFloat(defaults.double(forKey: widthKey)))
    }

    /// Stores a clamped width.
    static func setWidth(_ value: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: widthKey)
    }
}
