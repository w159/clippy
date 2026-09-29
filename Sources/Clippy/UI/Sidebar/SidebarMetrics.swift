import CoreGraphics

/// Layout constants and pure geometry decisions for the category sidebar.
enum SidebarMetrics {
    /// Narrowest the expanded sidebar may be dragged.
    static let expandedMinWidth: CGFloat = 150
    /// Widest the expanded sidebar may be, as a fraction of the panel width.
    static let expandedMaxFraction: CGFloat = 0.45
    /// Width of the icon rail shown when the sidebar is collapsed.
    static let railWidth: CGFloat = 52
    /// Panel widths below this always show the icon rail.
    static let collapseBreakpoint: CGFloat = 520
    /// Default expanded width; double-clicking the grabber restores it.
    static let defaultWidth: CGFloat = 176
    /// Hit strip width of the resize grabber.
    static let grabberWidth: CGFloat = 6

    /// Clamps a requested expanded width to
    /// `expandedMinWidth ... min(expandedMaxFraction * panelWidth, panelWidth - minContentWidth)`.
    /// The minimum always wins when the panel is too small to honor the maximum.
    static func clamp(width: CGFloat, panelWidth: CGFloat, minContentWidth: CGFloat) -> CGFloat {
        let upper = min(expandedMaxFraction * panelWidth, panelWidth - minContentWidth)
        return max(expandedMinWidth, min(width, upper))
    }

    /// True when the panel is too narrow for an expanded sidebar.
    static func shouldAutoCollapse(panelWidth: CGFloat) -> Bool {
        panelWidth < collapseBreakpoint
    }

    /// Whether the rail is shown: the user collapsed it, or the panel is too narrow.
    static func showsRail(isCollapsed: Bool, panelWidth: CGFloat) -> Bool {
        isCollapsed || shouldAutoCollapse(panelWidth: panelWidth)
    }
}
