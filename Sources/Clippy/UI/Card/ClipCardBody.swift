import SwiftUI

/// Content preview of `ClipCardView` (LAY-07: the content is the headline).
extension ClipCardView {
    @ViewBuilder
    var cardContent: some View {
        if model.isSensitive {
            MaskedText(clip.previewText, sensitive: true)
                .help("Sensitive. Hold to reveal.")
        } else if isImage {
            imagePreview
        } else if isFile {
            filePreview
        } else {
            switch kind {
            case .link: richLinkPreview
            case .colorValue(let swatch): colorPreview(swatch)
            default:
                if query.isEmpty { richCodePreview() } else { textPreview }
            }
        }
    }

    /// Body text with search matches marked; monospaced when it looks like code.
    var textPreview: some View {
        let isCode = CodeHeuristic.looksLikeCode(clip.previewText)
        return Text(HighlightedPreview.attributed(clip.previewText, query: query, color: tokens.accent))
            .font(isCode ? .system(size: CGFloat(settings.fontSizeBase) - 1, design: .monospaced) : PanelTypography.body(settings))
            .lineLimit(isCode ? 4 : 3)
            .foregroundStyle(tokens.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var linkPreview: some View {
        let text = clip.previewText
        let host = URL(string: text.hasPrefix("www.") ? "https://" + text : text)?.host ?? text
        return VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(HighlightedPreview.attributed(host, query: query, color: tokens.accent))
                    .font(PanelTypography.title(settings))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "globe").foregroundStyle(kindHue)
            }
            Text(HighlightedPreview.attributed(text, query: query, color: tokens.accent))
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .foregroundStyle(tokens.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func colorPreview(_ swatch: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(swatch)
                .frame(width: 44, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tokens.stroke, lineWidth: 1))
                .accessibilityHidden(true)
            Text(HighlightedPreview.attributed(clip.previewText, query: query, color: tokens.accent))
                .font(.system(size: CGFloat(settings.fontSizeBase), design: .monospaced))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
