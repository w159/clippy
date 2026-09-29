import SwiftUI

/// Collapsed item row: category icon, title, category label and an expand chevron.
struct OnePasswordItemRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: OPItem
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovered = false

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: OnePasswordFilter.symbol(forCategory: item.category))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                    Text(OnePasswordFilter.displayCategory(item.category))
                        .font(.caption2).foregroundStyle(tokens.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.textSecondary)
                    // One fixed chevron rotated so expand/collapse animates instead of popping.
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: isExpanded)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                isExpanded ? tokens.accent.opacity(0.10) : tokens.cardBorder.opacity(hovered ? 0.28 : 0.15),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(ClippyMotion.animation(.instant, reduce: reduceMotion), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Shows or hides the fields for this item.")
        .accessibilityAddTraits(.isButton)
    }
}
