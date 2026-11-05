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

    private let settings = AppSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Floating panel base: a system material with a light theme tint, so the
    /// glass controls above it have something to refract. Solid when the user
    /// asked for it or accessibility settings remove transparency. Content
    /// areas draw their own opaque cards on top.
    var body: some View {
        switch settings.panelMaterial.backdrop {
        case .solid:
            tokens.panel
        case _ where reduceTransparency || colorSchemeContrast == .increased:
            tokens.panel
        case .glass:
            ZStack {
                Rectangle().fill(.regularMaterial)
                tokens.panel.opacity(opacity * 0.45)
            }
        case .vibrancy:
            ZStack {
                Rectangle().fill(.thickMaterial)
                tokens.panel.opacity(opacity * 0.55)
            }
        }
    }
}
