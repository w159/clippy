import CoreGraphics
import Foundation

/// Sizing rules for the resizable output drawer under the script editor.
enum OutputDrawerMetrics {
    /// Smallest drawer that still shows the chip row and a line of output.
    static let minHeight: CGFloat = 96
    /// Height used before the user drags the handle.
    static let defaultHeight: CGFloat = 200
    /// The editor always keeps at least this much room above the drawer.
    static let minEditorHeight: CGFloat = 160
    /// UserDefaults key (prefixed `scripts.`) holding the persisted height.
    static let defaultsKey = "scripts.outputDrawerHeight"

    /// Clamps a requested drawer height so both the drawer and the editor keep
    /// their minimums inside `available` (the height of the whole detail column).
    static func clamp(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let ceiling = max(minHeight, available - minEditorHeight)
        guard proposed.isFinite else { return min(defaultHeight, ceiling) }
        return min(max(proposed, minHeight), ceiling)
    }

    /// New height after dragging the handle by `translation` points (negative = up = taller).
    static func height(start: CGFloat, translation: CGFloat, available: CGFloat) -> CGFloat {
        clamp(start - translation, available: available)
    }

    /// Reads the persisted height, falling back to the default when absent or invalid.
    static func stored(_ defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.double(forKey: defaultsKey)
        return value >= Double(minHeight) ? CGFloat(value) : defaultHeight
    }

    /// Persists a height (only sane values are written).
    static func store(_ height: CGFloat, defaults: UserDefaults = .standard) {
        guard height.isFinite, height >= minHeight else { return }
        defaults.set(Double(height), forKey: defaultsKey)
    }
}
