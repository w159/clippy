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

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        switch settings.panelMaterial.backdrop {
        case .solid:
            tokens.panel
        case .glass where reduceTransparency || colorSchemeContrast == .increased:
            solidFallback
        case .glass:
            ZStack {
                Rectangle().fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                tokens.panel.opacity(opacity)
            }
        case .vibrancy where reduceTransparency || colorSchemeContrast == .increased:
            solidFallback
        case .vibrancy:
            ZStack {
                VisualEffectBlur(material: settings.panelMaterial == .regular ? .hudWindow : .menu, isDark: tokens.isDark)
                tokens.panel.opacity(opacity)
            }
        }
    }

    /// High-contrast, opaque fallback when material transparency is unavailable.
    private var solidFallback: some View {
        tokens.panel.overlay {
            if colorSchemeContrast == .increased {
                RoundedRectangle(cornerRadius: 24).strokeBorder(tokens.cardBorder, lineWidth: 1.5)
            }
        }
    }
}
