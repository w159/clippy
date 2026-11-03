import SwiftUI

extension View {
    /// Menu chrome that draws its label exactly as written. The borderless menu styles
    /// hand the label to AppKit, which tints it with the accent color and drops custom
    /// backgrounds and strokes: the Date, App and Category filters rendered as gold text
    /// beside capsule chips, and "More" glyphs turned gold beside neutral icons.
    func chromeMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

/// Icon-only action for list rows and cards: secondary at rest, primary on hover, and
/// the danger color only while a destructive action is hovered, so a selected row does
/// not carry a red trash can next to every other neutral icon.
struct RowActionButton: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let systemImage: String
    let help: String
    var isDestructive = false
    var font: Font = .system(size: 13, weight: .medium)
    var width: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
                .font(font)
                .symbolRenderingMode(.hierarchical)
                .frame(width: width, height: 24)
                .contentShape(Rectangle())
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var foreground: Color {
        guard hovered else { return tokens.textSecondary }
        return isDestructive ? tokens.danger : tokens.textPrimary
    }
}

/// The "More" overflow glyph shared by rows and cards, drawn like `RowActionButton`.
struct RowOverflowLabel: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var hovered = false
    var font: Font = .system(size: 13, weight: .medium)
    var width: CGFloat = 24

    var body: some View {
        Image(systemName: "ellipsis")
            .font(font)
            .frame(width: width, height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(hovered ? tokens.textPrimary : tokens.textSecondary)
            .onHover { hovered = $0 }
    }
}
