import SwiftUI

/// Collapsed item row: category icon, title, category label and an expand chevron.
struct OnePasswordItemRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: OPItem
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: OnePasswordFilter.symbol(forCategory: item.category))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(OnePasswordFilter.displayCategory(item.category))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    // One fixed chevron rotated so expand/collapse animates instead of popping.
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: isExpanded)
            }
            .padding(10)
            .background(
                isExpanded ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(hovered ? 0.9 : 0.5)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
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
