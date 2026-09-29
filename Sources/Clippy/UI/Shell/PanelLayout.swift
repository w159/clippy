import CoreGraphics

/// Pure geometry for the popup panel's window: the smallest size at which the
/// icon rail, one grid card and the chrome still fit (PNL-03). Inputs are
/// passed in so the derivation is testable without the sidebar or grid types.
enum PanelLayout {
    /// Height of the header (search row, chip row and section title).
    static let headerHeight: CGFloat = 112
    /// Height of the shortcut footer.
    static let footerHeight: CGFloat = 32
    /// Width floor for the panel: the narrowest width at which the header controls
    /// (search field + toggles) stay usable. It is also the historical `minSize.width`,
    /// so `minimumSize` never returns a narrower panel even when rail + card + gutters
    /// would fit in less.
    static let absoluteMinimumWidth: CGFloat = 280
    /// Rows that must remain visible at the minimum height.
    static let minimumVisibleRows = 3
    /// Width of the divider between the sidebar and the content.
    static let dividerWidth: CGFloat = 1

    /// Smallest panel size: `railWidth + divider + minCardWidth + gutters` wide
    /// (never below `absoluteMinimumWidth`) and header + rows + footer tall.
    /// Negative or non-finite inputs are treated as zero.
    static func minimumSize(
        railWidth: CGFloat,
        minCardWidth: CGFloat,
        gutters: CGFloat,
        rowHeight: CGFloat,
        headerHeight: CGFloat = PanelLayout.headerHeight,
        footerHeight: CGFloat = PanelLayout.footerHeight,
        minimumWidth: CGFloat = PanelLayout.absoluteMinimumWidth,
        visibleRows: Int = PanelLayout.minimumVisibleRows
    ) -> CGSize {
        let content = safe(railWidth) + dividerWidth + safe(minCardWidth) + safe(gutters)
        let width = max(content, safe(minimumWidth))
        let rows = CGFloat(max(1, visibleRows))
        let height = safe(headerHeight) + rows * safe(rowHeight) + safe(footerHeight)
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    /// The panel's minimum size derived from the real sidebar and grid metrics.
    static var standardMinimumSize: CGSize {
        minimumSize(
            railWidth: SidebarMetrics.railWidth,
            minCardWidth: GridMetrics.minCardWidth,
            gutters: GridMetrics.listPadding * 2,
            rowHeight: GridMetrics.compactRowHeight
        )
    }

    /// Whether the sidebar shows as the icon rail at `panelWidth`.
    static func isRail(panelWidth: CGFloat, isCollapsed: Bool) -> Bool {
        SidebarMetrics.showsRail(isCollapsed: isCollapsed, panelWidth: panelWidth)
    }

    /// Raises `size` to at least `minimum` in each dimension (PNL-03). A saved
    /// or default size smaller than the layout can hold is clamped up, never down.
    static func clampUp(_ size: CGSize, toMinimum minimum: CGSize) -> CGSize {
        CGSize(width: max(safe(size.width), minimum.width), height: max(safe(size.height), minimum.height))
    }

    private static func safe(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
