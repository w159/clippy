import AppKit

/// PNL-06: remembers the panel's origin per display, keyed by `CGDirectDisplayID`,
/// so "last position" survives multi-display setups and unplugging. Stored in
/// UserDefaults under `panelOriginByDisplay` as `[displayID: [x, y]]`.
struct PanelDisplayMemory {
    static let key = "panelOriginByDisplay"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The Core Graphics display ID of `screen`, if AppKit exposes it.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Saved origin for a display.
    func origin(for display: CGDirectDisplayID) -> CGPoint? {
        guard let pair = stored()[String(display)], pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    func save(origin: CGPoint, for display: CGDirectDisplayID) {
        var all = stored()
        all[String(display)] = [Double(origin.x), Double(origin.y)]
        defaults.set(all, forKey: Self.key)
    }

    /// Drops entries for displays that are no longer connected.
    func prune(keeping connected: Set<CGDirectDisplayID>) {
        let all = stored()
        let kept = all.filter { UInt32($0.key).map(connected.contains) ?? false }
        if kept.count != all.count { defaults.set(kept, forKey: Self.key) }
    }

    private func stored() -> [String: [Double]] {
        defaults.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
    }
}

/// Geometry helper shared by PanelController and tests.
enum PanelGeometry {
    /// Inset kept between the panel and the screen edge.
    static let margin: CGFloat = 8

    /// Fits `rect` inside `bounds`: shrinks a panel that is larger than the
    /// available area (keeping the top edge visible), then slides it inside.
    static func clamp(_ rect: NSRect, within bounds: NSRect) -> NSRect {
        var result = rect
        result.size.width = min(result.width, max(0, bounds.width - 2 * margin))
        result.size.height = min(result.height, max(0, bounds.height - 2 * margin))
        result.origin.x = max(bounds.minX + margin, min(result.origin.x, bounds.maxX - result.width - margin))
        result.origin.y = max(bounds.minY + margin, min(result.origin.y, bounds.maxY - result.height - margin))
        return result
    }
}
