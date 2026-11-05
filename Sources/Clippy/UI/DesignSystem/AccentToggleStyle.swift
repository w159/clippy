import SwiftUI

/// Keeps the automatic switch or checkbox look but tints it with the bright `accent`. The Settings
/// window tints text-bearing buttons and links with the darker `accentInk` for contrast; toggles
/// carry no text in the tint, so they match every sheet and the panel instead.
struct AccentToggleStyle: ToggleStyle {
    @Environment(\.clippyTokens) private var tokens

    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).tint(tokens.accent)
    }
}

private struct AccentTintModifier: ViewModifier {
    @Environment(\.clippyTokens) private var tokens

    func body(content: Content) -> some View { content.tint(tokens.accent) }
}

extension View {
    /// Tints a control (slider, checkbox) with the bright `accent` instead of the window's `accentInk`.
    func accentTint() -> some View { modifier(AccentTintModifier()) }
}

extension Color {
    /// The theme accent (gold by default). Use instead of `Color.accentColor`, which is the system blue
    /// and ignores the app theme.
    @MainActor static var clippyAccent: Color { ClippyTokens.resolve(from: AppSettings.shared.theme).accent }
}
