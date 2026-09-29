import SwiftUI

/// Legend popover explaining every list badge (SCR-10). Each row shows the icon
/// exactly as it appears on a script row, with a title and a one-line meaning.
struct ScriptBadgeLegendView: View {
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            Text("Script badges").font(.headline).foregroundStyle(tokens.textPrimary)
            ForEach(ScriptBadge.allCases, id: \.title) { badge in
                HStack(alignment: .top, spacing: tokens.metrics.space.two) {
                    Image(systemName: badge.icon)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 22, height: 22)
                        .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.xs))
                        .foregroundStyle(badge.isCaution ? tokens.warning : tokens.textPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(badge.title).font(.callout.weight(.medium)).foregroundStyle(tokens.textPrimary)
                        Text(badge.detail).font(.caption).foregroundStyle(tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(tokens.metrics.space.four)
        .frame(width: 300)
    }
}

extension ScriptBadge {
    /// Badges that flag something to be careful about (drawn in the warning colour).
    var isCaution: Bool { self == .disabled || self == .confirms }
}
