import CoreGraphics

/// Pure layout math for the clip grid (LAY-02, LAY-04, LAY-05).
enum GridMetrics {
    /// Narrowest a card may get: 3pt accent + 2x12pt padding + the header minimum
    /// (glyph + short title + fixed-size timestamp).
    static let minCardWidth: CGFloat = 180
    /// Widest a card grows before another column is added on wide panels.
    static let maxCardWidth: CGFloat = 340
    /// Gap between cards and rows.
    static let spacing: CGFloat = 8
    /// Scroll content padding on each side.
    static let listPadding: CGFloat = 10
    /// Compact row height (LAY-08).
    static let compactRowHeight: CGFloat = 32
    /// Upper bound so absurd widths never create hairline columns of cards.
    static let maxColumns = 12

    /// Number of columns for a list of `width` points (padding included).
    /// Rows densities always use one column. Cards: auto picks the fewest
    /// columns that keep every card at or below `maxCardWidth`, never so many
    /// that a card drops under `minCardWidth`; fixed is capped by the latter.
    static func columnCount(forWidth width: CGFloat, preferred: GridColumnMode, density: ClipDensity) -> Int {
        guard density == .cards else { return 1 }
        let usable = width - listPadding * 2
        guard usable > 0 else { return 1 }
        let fit = max(1, min(maxColumns, Int(((usable + spacing) / (minCardWidth + spacing)).rounded(.down))))
        switch preferred {
        case .fixed(let requested):
            return max(1, min(requested, fit))
        case .auto:
            let wanted = Int(((usable + spacing) / (maxCardWidth + spacing)).rounded(.up))
            return max(1, min(fit, wanted))
        }
    }
}
