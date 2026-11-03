import SwiftUI

/// Filled primary button drawn entirely from tokens. `.borderedProminent` hands the fill to
/// AppKit, which paints a white label (about 2.2:1 on the gold accent) and drops the tint to
/// gray when the window is not key. This style fills with `tokens.accent`, labels with
/// `tokens.onAccent` (AA by construction) and looks the same in an inactive window.
/// Callers keep their own `.keyboardShortcut(.defaultAction)`.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: tokens.metrics.radius.control, style: .continuous)
        return configuration.label
            .font(.system(size: small ? 12 : 13, weight: .semibold))
            .foregroundStyle(tokens.onAccent)
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 3 : 6)
            .background(shape.fill(tokens.accent))
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    /// Accent-filled primary action with an AA-contrast label.
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}
