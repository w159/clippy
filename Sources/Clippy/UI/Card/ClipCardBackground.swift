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

    @ViewBuilder
    var cardBackground: some View {
        if settings.cardStyle == .plain {
            (isHovering ? tokens.textPrimary.opacity(0.06) : Color.clear)
        } else {
            ZStack {
                tokens.surfaceElevated
                if model.isSelected { tokens.selection }
                if isHovering { tokens.textPrimary.opacity(0.05) }
            }
        }
    }

    /// Selection draws the only colored stroke; otherwise a neutral hairline.
    var cardStroke: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                model.isSelected ? tokens.accent : (settings.cardStyle == .plain ? Color.clear : tokens.stroke),
                lineWidth: model.isSelected ? 2 : 1
            )
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
