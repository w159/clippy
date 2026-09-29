import SwiftUI
import AppKit

/// The panel's title bar: paperclip mark, "Clippy" wordmark and section title on the left,
/// sidebar / density / pin / settings / close controls on the right. The whole
/// strip is a window drag region (PNL-01); only the controls are hit-testable.
struct PanelHeaderView: View {
    /// Title of the pane being shown (section title).
    var sectionTitle: String = ""
    /// Number of clips in the pane; nil hides the count.
    var clipCount: Int?
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onToggleSidebar: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @ObservedObject private var grid = GridPreferences.shared
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let settings = AppSettings.shared

    var body: some View {
        ZStack {
            HStack(spacing: tokens.metrics.space.one) {
                Image(nsImage: StatusBarIcon.image())
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(tokens.accent)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                sectionLabel
                Spacer(minLength: 0)
                IconButton("sidebar.left", label: "Toggle sidebar", help: "Show or hide the sidebar", action: onToggleSidebar)
                IconButton(isPinned ? "pin.fill" : "pin", label: isPinned ? "Unpin panel" : "Pin panel",
                           help: isPinned ? "Unpin panel" : "Pin panel", state: isPinned ? .selected : .rest,
                           action: onTogglePin)
                    .accessibilityValue(isPinned ? "pinned" : "not pinned")
                    .accessibilityHint("Keeps the panel visible when you click elsewhere.")
                overflowMenu
                IconButton("xmark", label: "Close", action: onClose)
            }
            .padding(.horizontal, tokens.metrics.space.two)
        }
        .frame(height: 36)
        // Any area not covered by a control starts a window drag.
        .background(WindowDragRegion())
    }

    /// Section title with the clip count, e.g. "History  128".
    @ViewBuilder
    private var sectionLabel: some View {
        if !sectionTitle.isEmpty {
            Text(sectionTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(1)
                .allowsHitTesting(false)
            if let clipCount {
                Text("\(clipCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tokens.textSecondary)
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(clipCount) clips")
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
                columnButton("Auto columns", mode: .auto)
                ForEach(1...4, id: \.self) { count in
                    columnButton("\(count) \(count == 1 ? "column" : "columns")", mode: .fixed(count))
                }
            }
            Divider()
            Button("Settings\u{2026}", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(minWidth: 28, minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
