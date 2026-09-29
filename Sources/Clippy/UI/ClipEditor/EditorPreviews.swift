import AppKit
import MarkdownUI
import SwiftUI

// Preview panes for the clip editor (EDT-06c, FEAT-14): live markdown,
// CSV table, color swatches and the read-only rich-text view.

/// Rendered markdown beside the source. Reuses the assistant's MarkdownUI theme.
struct MarkdownPreviewPane: View {
    let markdown: String
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            Markdown(markdown)
                .markdownTheme(.clippy(tokens: settings.theme, settings: settings))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(settings.theme.cardSurface)
        .accessibilityLabel("Markdown preview")
    }
}

/// CSV rendered as an aligned grid: header row emphasized, columns sized to
/// their content (capped), rows capped by `CSVTable`.
struct CSVTablePreview: View {
    let table: CSVTable
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let tokens = settings.theme
        let widths = table.columnWidths()
        let charWidth = CGFloat(settings.fontSizeBase) * 0.62
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        ForEach(0..<widths.count, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(.system(size: CGFloat(settings.fontSizeBase) - 1,
                                              weight: index == 0 ? .semibold : .regular, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: CGFloat(widths[column]) * charWidth + 16, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                    }
                    .background(index == 0 ? tokens.headerBar : (index.isMultiple(of: 2) ? tokens.textSecondary.opacity(0.06) : .clear))
                    .foregroundStyle(tokens.textPrimary)
                }
                if table.truncatedRows > 0 {
                    Text("\(table.truncatedRows) more rows not shown")
                        .font(PanelTypography.metadata(settings))
                        .foregroundStyle(tokens.textSecondary)
                        .padding(8)
                }
            }
            .padding(8)
            .textSelection(.enabled)
        }
        .background(tokens.cardSurface)
        .accessibilityLabel("CSV table preview, \(table.rows.count) rows, \(table.columnCount) columns")
    }
}

/// A strip of swatches for color literals found in the text.
struct ColorSwatchStrip: View {
    let colors: [ColorValue]
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let tokens = settings.theme
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(colors, id: \.hex) { value in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(value.color)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(tokens.textSecondary.opacity(0.4), lineWidth: 1))
                        Text(value.hex)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Color \(value.hex)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(tokens.headerBar)
    }
}

/// Read-only, selectable rich text (RTF/HTML clips) in an NSTextView, so the
/// original formatting is shown while the source is edited as plain text.
struct RichPreviewView: NSViewRepresentable {
    let content: NSAttributedString
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.setAccessibilityLabel("Rich text preview")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let background = NSColor(settings.theme.cardSurface)
        view.backgroundColor = background
        scroll.backgroundColor = background
        if view.textStorage?.string != content.string || context.coordinator.shown !== content {
            view.textStorage?.setAttributedString(content)
            context.coordinator.shown = content
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var shown: NSAttributedString? }
}
