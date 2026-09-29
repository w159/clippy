import SwiftUI

/// Title row (only for user-named clips or while renaming) and the metadata row
/// of `ClipCardView` (LAY-03, LAY-06, LAY-07).
extension ClipCardView {
    /// The user's own name is the only title; otherwise content is the headline.
    var showsTitleRow: Bool { isRenaming || (clip.userTitle != nil && !model.isSensitive) }

    var titleRow: some View {
        Group {
            if isRenaming {
                titleEditor
            } else {
                Text(clip.displayTitle)
                    .font(PanelTypography.title(settings))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Metadata row with graceful degradation; actions crossfade over it.
    var metadataRow: some View {
        ViewThatFits(in: .horizontal) {
            metadataContent(.full)
            metadataContent(.noAppName)
            metadataContent(.essentialsWithIcon)
            metadataContent(.minimal)
        }
        .frame(minHeight: 22)
        .opacity(showsActions ? 0 : 1)
        .overlay(alignment: .trailing) {
            fittingHoverActions
                .padding(.horizontal, 4)
                .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
    }

    func metadataContent(_ variant: CardHeaderPlan.Variant) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind.iconName)
                .font(.system(size: iconSize - 1, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(kindHue)
                .help(kind.label)
            if variant.kept.contains(.appIcon) { sourceIcon }
            if variant.kept.contains(.appName), let name = clip.sourceAppName {
                Text(name)
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if variant.kept.contains(.categories) { categoryDots }
            if variant.kept.contains(.richBadge), clip.isRich {
                Image(systemName: "textformat")
                    .font(.system(size: iconSize - 1))
                    .foregroundStyle(tokens.textSecondary)
                    .help("Has rich formatting")
            }
            if model.isSensitive { Image(systemName: "lock.fill").font(.system(size: iconSize - 2)).foregroundStyle(tokens.textSecondary) }
            if model.matchedInOCR { ClippyBadge("OCR match") }
            Spacer(minLength: 4)
            if isPinned { Image(systemName: "pin.fill").font(.system(size: iconSize - 1)).foregroundStyle(tokens.accentText) }
            if let digit = model.quickPasteDigit { KeyCap("\u{2325}\u{2318}\(digit)") }
            timestampText
        }
    }

    @ViewBuilder
    var sourceIcon: some View {
        if let category = pinnedCategory {
            categoryIcon(category).frame(width: 14, height: 14)
        } else if settings.showAppIcons, let icon = AppIconProvider.shared.icon(forBundleID: clip.sourceAppBundleID) {
            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
        }
    }

    /// Renders any of the three category icon kinds.
    @ViewBuilder
    func categoryIcon(_ category: Category) -> some View {
        switch category.iconKind {
        case .symbol:
            Image(systemName: category.iconValue)
                .font(.system(size: iconSize - 1, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(hexString: category.colorHex))
        case .emoji:
            Text(category.iconValue).font(.system(size: iconSize))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: category.iconValue) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(tokens.textSecondary)
            }
        }
    }

    var categoryDots: some View {
        HStack(spacing: 3) {
            ForEach(Array(categoryColors.prefix(3).enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
    }

    /// Fixed-size, never wraps, highest layout priority (LAY-03).
    var timestampText: some View {
        Text(RelativeTime.string(for: clip.createdAt))
            .font(PanelTypography.metadata(settings))
            .foregroundStyle(tokens.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(3)
    }
}
