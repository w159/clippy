import SwiftUI

/// Places a text block and a control side by side, or stacks the control under the text
/// when the row is too narrow for both, so nothing is ever squeezed or clipped.
struct SettingsRowLayout: Layout {
    /// Narrowest useful width for the text block before the control wraps below it.
    var minTextWidth: CGFloat = 180
    var spacing: CGFloat = 16
    var stackedSpacing: CGFloat = 8

    private func isHorizontal(width: CGFloat, control: CGSize) -> Bool {
        control.width == 0 || control.width + minTextWidth + spacing <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let control = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (subviews[0].sizeThatFits(.unspecified).width + control.width + spacing)
        if isHorizontal(width: width, control: control) {
            let textWidth = control.width == 0 ? width : width - control.width - spacing
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            return CGSize(width: width, height: max(text.height, control.height))
        }
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let stacked = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: text.height + stackedSpacing + stacked.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let control = subviews[1].sizeThatFits(.unspecified)
        if isHorizontal(width: bounds.width, control: control) {
            let textWidth = control.width == 0 ? bounds.width : bounds.width - control.width - spacing
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY - text.height / 2), anchor: .topLeading,
                proposal: ProposedViewSize(width: textWidth, height: text.height))
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY - control.height / 2), anchor: .topTrailing,
                proposal: ProposedViewSize(width: control.width, height: control.height))
            return
        }
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: text.height))
        let stacked = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + text.height + stackedSpacing), anchor: .topLeading,
            proposal: ProposedViewSize(width: min(stacked.width, bounds.width), height: stacked.height))
    }
}

/// Aligned settings row: 13pt title with 12pt secondary description on the left, control on
/// the right. The control drops under the text when the row is narrow. Persistence stays with
/// the caller.
struct SettingsRow<Control: View>: View {
    @Environment(\.clippyTokens) private var tokens
    let title: LocalizedStringKey
    let detail: Text?
    let enabled: Bool
    let control: Control

    /// Creates a settings row with a native caller-owned control.
    init(title: LocalizedStringKey, detail: Text? = nil, enabled: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.enabled = enabled
        self.control = control()
    }

    var body: some View {
        SettingsRowLayout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Text(title))
                if let detail {
                    detail
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A control made of several buttons or fields (backup actions, add-rule rows) stacks its
            // parts vertically when even the full-width row cannot hold them side by side.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: tokens.metrics.space.two) { control }
                VStack(alignment: .leading, spacing: tokens.metrics.space.two) { control }
            }
            .toggleStyle(.switch)
            .lineLimit(1)
        }
        .padding(.vertical, tokens.metrics.space.three)
        .frame(minHeight: 44)
        .opacity(enabled ? 1 : 0.68)
        .disabled(!enabled)
    }
}
