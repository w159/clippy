import AppKit
import SwiftUI

/// Sidebar + content split with a 6pt resize grabber and an icon-rail mode.
///
/// The sidebar closure receives `isRail`, true when collapsed by the user or
/// auto-collapsed below `SidebarMetrics.collapseBreakpoint`. Width and collapse
/// state persist through `SidebarPreferences.shared`.
struct SidebarSplitView<Sidebar: View, Content: View>: View {
    @ObservedObject private var preferences = SidebarPreferences.shared
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStartWidth: CGFloat?
    @State private var grabberHovered = false

    private let minContentWidth: CGFloat
    private let sidebar: (_ isRail: Bool) -> Sidebar
    private let content: Content

    /// Creates the split; `minContentWidth` reserves room for at least one card.
    init(
        minContentWidth: CGFloat,
        @ViewBuilder sidebar: @escaping (_ isRail: Bool) -> Sidebar,
        @ViewBuilder content: () -> Content
    ) {
        self.minContentWidth = minContentWidth
        self.sidebar = sidebar
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = proxy.size.width
            let isRail = SidebarMetrics.showsRail(isCollapsed: preferences.isCollapsed, panelWidth: panelWidth)
            let width = displayWidth(isRail: isRail, panelWidth: panelWidth)
            HStack(spacing: 0) {
                sidebar(isRail)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .clipped()
                if isRail {
                    Rectangle().fill(tokens.stroke).frame(width: 1)
                } else {
                    grabber(panelWidth: panelWidth)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isRail)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clippyToggleSidebar)) { _ in
            preferences.toggleCollapsed()
        }
        .background(shortcutButton)
    }

    private func displayWidth(isRail: Bool, panelWidth: CGFloat) -> CGFloat {
        isRail
            ? SidebarMetrics.railWidth
            : SidebarMetrics.clamp(width: preferences.width, panelWidth: panelWidth, minContentWidth: minContentWidth)
    }

    /// Hidden button that supplies the Cmd+Ctrl+S shortcut while the panel is key.
    private var shortcutButton: some View {
        Button("Toggle Sidebar") {
            NotificationCenter.default.post(name: .clippyToggleSidebar, object: nil)
        }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func grabber(panelWidth: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.clear)
            Rectangle().fill(grabberHovered || dragStartWidth != nil ? tokens.accent : tokens.stroke)
                .frame(width: grabberHovered || dragStartWidth != nil ? 2 : 1)
        }
        .frame(width: SidebarMetrics.grabberWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            grabberHovered = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? currentWidth(panelWidth: panelWidth)
                    dragStartWidth = start
                    preferences.width = SidebarMetrics.clamp(
                        width: start + value.translation.width, panelWidth: panelWidth, minContentWidth: minContentWidth)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { preferences.resetWidth() })
        .accessibilityElement()
        .accessibilityLabel("Sidebar width")
        .accessibilityValue("\(Int(currentWidth(panelWidth: panelWidth))) points")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 16 : -16
            preferences.width = SidebarMetrics.clamp(
                width: currentWidth(panelWidth: panelWidth) + step, panelWidth: panelWidth, minContentWidth: minContentWidth)
        }
    }

    private func currentWidth(panelWidth: CGFloat) -> CGFloat {
        SidebarMetrics.clamp(width: preferences.width, panelWidth: panelWidth, minContentWidth: minContentWidth)
    }
}
