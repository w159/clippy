import SwiftUI

/// Visual chrome for `ClipCardView` (LAY-09): a solid surface, a neutral
/// hairline, a slim per-kind accent bar, and a colored stroke for selection only.
/// The old Bordered/tinted styles are folded into the filled surface; `.plain`
/// keeps its chrome-free look.
extension ClipCardView {
    /// Per-kind hue from the design tokens.
    var kindHue: Color {
        if case .colorValue(let swatch) = kind { return swatch }
        return tokens.kind(Self.style(for: kind, clip: clip))
    }

    /// Maps a clip to its semantic style (code is detected heuristically).
    static func style(for kind: ClipKind, clip: Clip) -> ClipKindStyle {
        switch kind {
        case .link: return .link
        case .email: return .email
        case .colorValue: return .color
        case .filePath, .file: return .file
        case .image: return .image
        case .text: return CodeHeuristic.looksLikeCode(clip.previewText) ? .code : .text
        }
    }

    /// Slim leading accent; per-kind hue, never the selection signal.
    var accentBar: some View {
        Capsule()
            .fill(kindHue)
            .frame(width: 3)
            .padding(.vertical, 8)
            .padding(.leading, 5)
            .accessibilityHidden(true)
    }

    /// Settings resolved to draw values (read once per body, like `settings`).
    var cardAppearance: CardAppearance {
        CardAppearance.resolve(style: settings.cardStyle, colorMode: settings.cardColorMode,
                               tintStrength: settings.cardTintStrength, highContrast: settings.highContrastCardText)
    }

    /// Color of the face tint for the active "Card color" mode.
    var cardTintColor: Color? {
        switch cardAppearance.tint {
        case .none: return nil
        case .sourceApp: return AppIconProvider.shared.dominantColor(forBundleID: clip.sourceAppBundleID)
        case .kind: return kindHue
        case .accent: return tokens.accent
        }
    }

    /// Metadata and secondary lines; primary when "High-contrast card text" is on.
    var cardSecondaryText: Color {
        cardAppearance.usesPrimaryForSecondaryText ? tokens.textPrimary : tokens.textSecondary
    }

    @ViewBuilder
    var cardBackground: some View {
        let appearance = cardAppearance
        if appearance.edge == .none {
            (isHovering ? tokens.textPrimary.opacity(0.06) : Color.clear)
        } else {
            ZStack {
                if appearance.face == .solid { tokens.surfaceElevated }
                if let tint = cardTintColor { tint.opacity(appearance.tintOpacity) }
                if model.isSelected { tokens.selection }
                if isHovering { tokens.textPrimary.opacity(0.05) }
            }
        }
    }

    /// Selection draws the only colored stroke; otherwise a neutral outline
    /// (hairline for Filled, stronger for Bordered, none for Plain).
    var cardStroke: some View {
        let edge = cardAppearance.edge
        let rest: Color = edge == .none ? .clear : (edge == .strong ? tokens.strokeStrong : tokens.stroke)
        return RoundedRectangle(cornerRadius: ClippyRadius.card, style: .continuous)
            .strokeBorder(model.isSelected ? tokens.accent : rest, lineWidth: model.isSelected ? 2 : 1)
    }
}

/// Cheap, pure "does this text look like source code" check for the code hue
/// and monospaced preview.
enum CodeHeuristic {
    /// True when at least two independent code signals are present.
    static func looksLikeCode(_ text: String) -> Bool {
        guard text.count >= 8 else { return false }
        var signals = 0
        let starters = ["func ", "import ", "def ", "class ", "const ", "let ", "var ", "return ", "#include", "public ", "if (", "for ("]
        if starters.contains(where: { text.hasPrefix($0) || text.contains("\n" + $0) }) { signals += 1 }
        if text.contains("{") && text.contains("}") { signals += 1 }
        if text.contains(";\n") || text.hasSuffix(";") { signals += 1 }
        if text.contains("=>") || text.contains("->") || text.contains("==") || text.contains("</") { signals += 1 }
        if text.contains("\n    ") || text.contains("\n\t") { signals += 1 }
        return signals >= 2
    }
}
