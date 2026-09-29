import SwiftUI

/// Theme-aware panel backdrop styles. The five persisted setting values map to
/// glass, vibrancy, or solid without changing their raw values.
enum PanelBackdropStyle {
    case glass, vibrancy, solid
}

/// A shared navigation-layer surface using macOS 26 Liquid Glass and an
/// accessibility-safe, contrast-aware solid/material fallback.
struct GlassSurface<Content: View>: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @FocusState private var focused: Bool

    private let shape: AnyShape
    private let interactive: Bool
    private let content: Content

    /// Creates a glass control-layer container with the provided shape.
    init<S: Shape>(in shape: S, interactive: Bool = false, @ViewBuilder content: () -> Content) {
        self.shape = AnyShape(shape)
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        content
            .padding(tokens.metrics.space.two)
            .background {
                if reduceTransparency || contrast == .increased {
                    shape.fill(tokens.surfaceElevated)
                } else {
                    shape.fill(.clear).glassEffect(.regular.interactive(interactive), in: shape)
                }
            }
            .overlay {
                if reduceTransparency || contrast == .increased {
                    shape.stroke(contrast == .increased ? tokens.strokeStrong : tokens.stroke, lineWidth: contrast == .increased ? 1.5 : 1)
                }
            }
            .overlay {
                if focused { shape.stroke(tokens.focusRing, lineWidth: 2).padding(-2) }
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(ClippyMotion.animation(.instant, reduce: reduceMotion), value: hovered)
            .accessibilityElement(children: .contain)
    }
}

/// GlassEffectContainer groups nearby glass shapes into a shared sampling region.
struct GlassCluster<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    /// Creates one independently acting glass cluster (default 8pt spacing).
    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View { GlassEffectContainer(spacing: spacing) { content } }
}
