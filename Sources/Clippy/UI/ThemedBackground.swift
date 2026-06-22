import AppKit
import SwiftUI

// The panel's outermost background. At full opacity it is a solid theme color
// (the fix for the washed-out glass look). Below full opacity a real blur layer
// shows the desktop through the tinted color, which is the working transparency
// slider. Inner surfaces (cards) stay opaque so text never loses contrast.

/// AppKit vibrancy layer behind the window. Used only when the user dials
/// transparency below 1.0.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

struct ThemedPanelBackground: View {
    let tokens: ThemeTokens
    let opacity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if opacity >= 0.999 || reduceTransparency {
            // At full opacity, or when the user has enabled Reduce Transparency
            // (System Settings > Accessibility > Display), render the solid
            // theme color and skip the blur. The blur layer depends on desktop
            // content showing through; reduce-transparency users explicitly opt
            // out of that, so we honor the preference and render tokens.panel at
            // full opacity for guaranteed legible contrast.
            tokens.panel
        } else {
            ZStack {
                VisualEffectBlur(material: .hudWindow, isDark: tokens.isDark)
                tokens.panel.opacity(opacity)
            }
        }
    }
}
