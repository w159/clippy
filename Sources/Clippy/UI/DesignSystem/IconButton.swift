import SwiftUI

/// Compact icon-only action with accessible naming, tooltip, focus ring and hover reveal.
struct IconButton: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @FocusState private var focused: Bool
    let systemImage: String
    let label: String
    let help: String
    let state: ControlState
    let glass: Bool
    let action: () -> Void

    /// Creates a named icon action; glass styling is intended for a grouped toolbar only.
    init(_ systemImage: String, label: String, help: String? = nil, state: ControlState = .rest, glass: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.help = help ?? label
        self.state = state
        self.glass = glass
        self.action = action
    }

    /// Dims for both the explicit state and an enclosing `.disabled(...)`.
    private var dimmed: Bool { state == .disabled || !isEnabled }

    @ViewBuilder
    var body: some View {
        if glass {
            glassButton
        } else {
            button.buttonStyle(.plain)
        }
    }

    /// Toolbar variant: a 24pt circular Liquid Glass button. Neutral glass; only an active toggle (pinned) takes the accent.
    private var glassButton: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(state == .selected ? tokens.accentText : tokens.textPrimary)
                .glassEffect(state == .selected ? .regular.tint(tokens.accent).interactive() : .regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .disabled)
        .help(help)
        .accessibilityLabel(label)
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.medium))
                .frame(minWidth: 24, minHeight: 24)
                .foregroundStyle(dimmed ? tokens.textSecondary : tokens.textPrimary)
                .background((hovered || state == .pressed || state == .selected) ? tokens.surfaceInset : .clear, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .overlay { if focused || state == .focused { RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.focusRing, lineWidth: 2).padding(-2) } }
                .opacity(dimmed ? 0.65 : 1)
                .contentShape(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        }
        .focused($focused)
        .onHover { hovered = $0 }
        .disabled(state == .disabled)
        .animation(ClippyMotion.animation(.instant, reduce: reduceMotion), value: hovered)
        .help(help)
        .accessibilityLabel(label)
    }
}
