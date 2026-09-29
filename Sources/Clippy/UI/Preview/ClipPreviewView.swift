import SwiftUI

/// Renders a `ClipPreviewItem` with design-system tokens. Sensitive clips render only a mask.
struct ClipPreviewView: View {
    @Environment(\.clippyTokens) private var tokens
    let item: ClipPreviewItem
    /// Lines kept for code/text; nil = unlimited (large sheet).
    var lineLimit: Int?

    var body: some View {
        switch item {
        case .masked:
            MaskedText("", sensitive: true)
        case .text(let text), .markdown(let text):
            Text(limited(text)).font(.body).foregroundStyle(tokens.textPrimary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .json(let text):
            Text(limited(Self.prettyJSON(text))).font(.system(.body, design: .monospaced))
                .foregroundStyle(tokens.textPrimary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .code(let text, let language, let dropped):
            codeView(text, language: language, dropped: dropped)
        case .csv(let table):
            CSVPreviewGrid(table: table)
        case .image(let url, _, _):
            imageView(url)
        case .file(let path, let name):
            fileView(path: path, name: name)
        case .color(let value):
            colorView(value)
        case .link(let url):
            LinkPreviewCard(url: url)
        }
    }

    private func limited(_ text: String) -> String {
        guard let lineLimit else { return text }
        return ClipPreviewProvider.capLines(text, limit: lineLimit).text
    }

    /// Pretty-prints valid JSON, otherwise returns the input.
    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return text }
        return String(decoding: out, as: UTF8.self)
    }

    private func codeView(_ text: String, language: CodeLanguage, dropped: Int) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Text(CodePreviewStyler.attributed(text, language: language, tokens: tokens))
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if dropped > 0 {
                Text("\u{2026} \(dropped) more lines").font(.caption).foregroundStyle(tokens.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func imageView(_ url: URL?) -> some View {
        if let url, let image = NSImage(contentsOf: url) {
            PreviewCheckerboard(tileSize: 12) { Image(nsImage: image).resizable().scaledToFit() }
                .frame(maxWidth: .infinity, maxHeight: 360)
        } else {
            Label("Image unavailable", systemImage: "photo").foregroundStyle(tokens.textSecondary)
        }
    }

    private func fileView(path: String, name: String) -> some View {
        HStack(spacing: tokens.metrics.space.two) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading) {
                Text(name).font(.headline).foregroundStyle(tokens.textPrimary)
                Text(path).font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(3)
            }
        }
    }

    private func colorView(_ value: ColorValue) -> some View {
        HStack(spacing: tokens.metrics.space.three) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(value.color).frame(width: 72, height: 72)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tokens.stroke))
            VStack(alignment: .leading) {
                Text(value.literal).font(.system(.body, design: .monospaced)).foregroundStyle(tokens.textPrimary)
                Text(value.hex).font(.caption).foregroundStyle(tokens.textSecondary)
            }
        }
    }
}

/// Builds the highlighted `AttributedString` for code previews with the app's tokenizer.
enum CodePreviewStyler {
    /// Highlighted string; token colors come from the design tokens.
    static func attributed(_ text: String, language: CodeLanguage, tokens: ClippyTokens) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = tokens.textPrimary
        let utf16 = Array(text.utf16)
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            guard token.range.location >= 0, token.range.location + token.range.length <= utf16.count,
                  let range = Range(token.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color(token.kind, tokens)
        }
        return result
    }

    private static func color(_ kind: CodeTokenKind, _ tokens: ClippyTokens) -> Color {
        switch kind {
        case .keyword: return tokens.accentText
        case .string: return tokens.success
        case .comment: return tokens.textSecondary
        case .number: return tokens.danger
        case .type, .function, .attribute: return tokens.warning
        case .variable, .op: return tokens.textPrimary
        }
    }
}

/// Read-only CSV table for previews.
struct CSVPreviewGrid: View {
    @Environment(\.clippyTokens) private var tokens
    let table: CSVTable

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: tokens.metrics.space.three, verticalSpacing: 4) {
                ForEach(Array(table.rows.prefix(50).enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.prefix(CSVTable.maxColumns).enumerated()), id: \.offset) { _, cell in
                            Text(cell).lineLimit(1).font(index == 0 ? .callout.bold() : .callout)
                                .foregroundStyle(tokens.textPrimary)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }
}

/// Link card: shows only the address unless the user opted in to fetching metadata.
struct LinkPreviewCard: View {
    @Environment(\.clippyTokens) private var tokens
    let url: URL
    @State private var metadata: LinkPreviewMetadata?

    var body: some View {
        HStack(spacing: tokens.metrics.space.two) {
            if let data = metadata?.iconPNG, let icon = NSImage(data: data) {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            } else {
                Image(systemName: "globe").font(.title2).foregroundStyle(tokens.textSecondary)
            }
            VStack(alignment: .leading) {
                Text(metadata?.title ?? url.host ?? url.absoluteString).font(.headline).foregroundStyle(tokens.textPrimary)
                Text(url.absoluteString).font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(2)
            }
        }
        .task(id: url) { metadata = await LinkPreviewService.shared.metadata(for: url, sensitive: false) }
    }
}
