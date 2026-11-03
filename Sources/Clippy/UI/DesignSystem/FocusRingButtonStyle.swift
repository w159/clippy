import SwiftUI

/// Plain button look that draws the design-system focus ring while the button has keyboard
/// focus. `.buttonStyle(.plain)` hides the system ring, which leaves keyboard users blind.
struct FocusRingButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 6))

    func makeBody(configuration: Configuration) -> some View {
        FocusRingBody(configuration: configuration, shape: shape)
    }
}

private struct FocusRingBody: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.isFocused) private var focused
    let configuration: ButtonStyleConfiguration
    let shape: AnyShape

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .overlay { if focused { shape.strokeBorder(tokens.focusRing, lineWidth: 2).padding(-2) } }
    }
}
