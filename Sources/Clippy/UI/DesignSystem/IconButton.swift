import SwiftUI

/// Compact icon-only action with accessible naming, tooltip, focus ring and hover reveal.
struct IconButton: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    @ViewBuilder
    var body: some View {
        if glass {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.plain)
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(minWidth: 28, minHeight: 28)
                .foregroundStyle(state == .disabled ? tokens.textSecondary : tokens.textPrimary)
                .background((hovered || state == .pressed || state == .selected) ? tokens.surfaceInset : .clear, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .overlay { if focused || state == .focused { RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.focusRing, lineWidth: 2).padding(-2) } }
                .opacity(state == .disabled ? 0.65 : 1)
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
