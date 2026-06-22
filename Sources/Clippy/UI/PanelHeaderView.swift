import SwiftUI
import AppKit

/// An AppKit view that hands the panel drag to the Window Server. Overriding
/// mouseDown to call performDrag is the documented way to drag a borderless /
/// non-activating panel from a custom region. Attached behind the header
/// content so any area not covered by a hit-testable control starts the drag.
private final class DragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The panel's title bar: paperclip mark + "Clippy" wordmark on the left,
/// pin / settings / close controls on the right. The whole strip is draggable
/// except for the buttons.
struct PanelHeaderView: View {
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Dynamic Type: scale the header button glyph with the system text size.
    // The central PanelTypography fix belongs to Theme (owned separately), so
    // this is a local adoption for fonts built directly in this view.
    @ScaledMetric(relativeTo: .body) private var headerButtonSize: CGFloat = 11

    private var tokens: ThemeTokens { AppSettings.shared.theme }
    private let settings = AppSettings.shared

    var body: some View {
        ZStack {
            // Sits behind the content; receives mouse-down on any area not covered
            // by a hit-testable control, and hands the drag to the Window Server.
            WindowDragArea()
            HStack(spacing: 8) {
                Image(nsImage: StatusBarIcon.image())
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(tokens.accent)
                    // Hit-transparent so mouse-downs on the mark fall through to
                    // WindowDragArea and start a window drag.
                    .allowsHitTesting(false)
                Text("Clippy")
                    .font(PanelTypography.title(settings))
                    .foregroundStyle(tokens.textPrimary)
                    // Hit-transparent for the same reason as the mark above.
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: headerButtonSize, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isPinned ? tokens.accent : tokens.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        // Swap pin <-> pin.fill as a symbol replace, and bounce
                        // once on the pin/unpin toggle so the state change registers.
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .symbolEffect(.bounce, value: reduceMotion ? false : isPinned)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin panel" : "Pin panel")
                .accessibilityLabel(isPinned ? "Unpin panel" : "Pin panel")
                .accessibilityValue(isPinned ? "pinned" : "not pinned")
                .accessibilityHint("Keeps the panel visible when you click elsewhere.")
                headerButton(systemName: "gearshape",
                             help: "Settings", action: onOpenSettings)
                headerButton(systemName: "xmark",
                             help: "Close", action: onClose)
            }
            // Container stays hit-testable so the three buttons keep working.
            .allowsHitTesting(true)
            .padding(.horizontal, 12)
        }
        .frame(height: 30)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }

    private func headerButton(systemName: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: headerButtonSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
