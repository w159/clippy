import SwiftUI
import AppKit

/// The panel's single 44pt top row: section title and count on the left, the search
/// field filling the middle, sidebar / pin / more / close controls on the right. The whole
/// strip is a window drag region (PNL-01); only the field and the controls are hit-testable.
struct PanelHeaderView<Search: View>: View {
    /// Title of the pane being shown (section title).
    var sectionTitle: String = ""
    /// Number of clips in the pane; nil hides the count.
    var clipCount: Int?
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onToggleSidebar: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    /// The search field shown between title and controls; empty for panes without search.
    private let search: Search

    @Bindable private var grid = GridPreferences.shared
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overflowHovered = false

    private let settings = AppSettings.shared

    /// Creates the header; `search` is the field that fills the middle of the row.
    init(
        sectionTitle: String = "", clipCount: Int? = nil, isPinned: Bool,
        onTogglePin: @escaping () -> Void, onToggleSidebar: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void, onClose: @escaping () -> Void,
        @ViewBuilder search: () -> Search
    ) {
        self.sectionTitle = sectionTitle
        self.clipCount = clipCount
        self.isPinned = isPinned
        self.onTogglePin = onTogglePin
        self.onToggleSidebar = onToggleSidebar
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.search = search()
    }

    var body: some View {
        ZStack {
            HStack(spacing: tokens.metrics.space.one) {
                sectionLabel
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                if Search.self == EmptyView.self {
                    Spacer(minLength: 0)
                } else {
                    search
                        .padding(.horizontal, tokens.metrics.space.two)
                        .frame(height: 30)
                        .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                        .frame(minWidth: 120, maxWidth: .infinity)
                }
                IconButton("sidebar.left", label: "Toggle sidebar", help: "Show or hide the sidebar", action: onToggleSidebar)
                IconButton(isPinned ? "pin.fill" : "pin", label: isPinned ? "Unpin panel" : "Pin panel",
                           help: isPinned ? "Unpin panel" : "Pin panel", state: isPinned ? .selected : .rest,
                           action: onTogglePin)
                    .accessibilityValue(isPinned ? "pinned" : "not pinned")
                    .accessibilityHint("Keeps the panel visible when you click elsewhere.")
                overflowMenu
                IconButton("xmark", label: "Close", action: onClose)
            }
            .padding(.horizontal, tokens.metrics.space.three)
        }
        .frame(height: PanelLayout.headerHeight)
        // Any area not covered by a control starts a window drag.
        .background(WindowDragRegion())
    }

    /// Section title with the clip count, e.g. "History  128".
    @ViewBuilder
    private var sectionLabel: some View {
        if !sectionTitle.isEmpty {
            Text(sectionTitle)
                .font(.headline)
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(1)
                .allowsHitTesting(false)
            if let clipCount {
                Text("\(clipCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tokens.textSecondary)
                    .allowsHitTesting(false)
                    .accessibilityLabel(CopyFormat.counted(clipCount, "clip"))
            }
        }
    }

    /// Secondary controls (density, columns, settings) behind one overflow button;
    /// density writes `GridPreferences.shared`.
    private var overflowMenu: some View {
        Menu {
            Picker("Density", selection: $grid.density) {
                ForEach(ClipDensity.allCases, id: \.self) { density in
                    Label(density.title, systemImage: density.symbolName).tag(density)
                }
            }
            if grid.density == .cards {
                Divider()
                columnButton("Auto Columns", mode: .auto)
                ForEach(1...4, id: \.self) { count in
                    columnButton("\(count) \(count == 1 ? "Column" : "Columns")", mode: .fixed(count))
                }
            }
            Divider()
            Button("Settings\u{2026}", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(minWidth: 28, minHeight: 28)
                .foregroundStyle(tokens.textPrimary)
                .background(overflowHovered ? tokens.surfaceInset : .clear,
                            in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .contentShape(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .onHover { overflowHovered = $0 }
        }
        .chromeMenuStyle()
        .fixedSize()
        .help("Density, columns and settings")
        .accessibilityLabel("More")
        .accessibilityHint("Density, columns and settings.")
    }

    private func columnButton(_ title: String, mode: GridColumnMode) -> some View {
        Button {
            grid.columnMode = mode
        } label: {
            if grid.columnMode == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

extension PanelHeaderView where Search == EmptyView {
    /// Header for panes without a search field.
    init(
        sectionTitle: String = "", clipCount: Int? = nil, isPinned: Bool,
        onTogglePin: @escaping () -> Void, onToggleSidebar: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.init(sectionTitle: sectionTitle, clipCount: clipCount, isPinned: isPinned, onTogglePin: onTogglePin,
                  onToggleSidebar: onToggleSidebar, onOpenSettings: onOpenSettings, onClose: onClose) { EmptyView() }
    }
}
