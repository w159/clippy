import Foundation
import SwiftUI

/// What a preview surface (column, Quick Look sheet, card hook) should render for one clip.
/// Sensitive clips only ever produce `.masked`: no content is carried by that case.
enum ClipPreviewItem: Equatable {
    /// Sensitive clip: the view renders a mask, never the content.
    case masked
    /// Plain text (prose).
    case text(String)
    /// Source code with the sniffed language, already capped to the line limit.
    case code(text: String, language: CodeLanguage, truncatedLines: Int)
    /// Markdown source.
    case markdown(String)
    /// Pretty-printable JSON source.
    case json(String)
    /// Parsed delimited table.
    case csv(CSVTable)
    /// Image clip; `url` is the full-size media file when it exists.
    case image(url: URL?, width: Int?, height: Int?)
    /// File clip: absolute path and display name.
    case file(path: String, name: String)
    /// Color literal.
    case color(ColorValue)
    /// Single http(s) link.
    case link(URL)

    /// Short label for the kind, shown in the column metadata.
    var kindLabel: String {
        switch self {
        case .masked: return "Sensitive"
        case .text: return "Text"
        case .code: return "Code"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .csv: return "Table"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        case .link: return "Link"
        }
    }
}

/// Chooses the preview item for a clip. Pure apart from the sensitivity lookup, which is injectable.
enum ClipPreviewProvider {
    /// Lines kept for code previews.
    static let codeLineLimit = 40
    /// Characters examined when classifying text.
    static let classificationWindow = 20_000

    /// Builds the item. `isSensitive` defaults to the cached card sensitivity check.
    static func item(for clip: Clip, lineLimit: Int = codeLineLimit,
                     isSensitive: (Clip) -> Bool = { CardSensitivity.isSensitive($0) }) -> ClipPreviewItem {
        if isSensitive(clip) { return .masked }
        switch clip.contentKind {
        case .image:
            return .image(url: ClipCardView.previewURL(for: clip), width: clip.pixelWidth, height: clip.pixelHeight)
        case .file:
            let path = clip.filePath ?? clip.contentText
            return .file(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
        case .text:
            return textItem(clip.contentText, lineLimit: lineLimit)
        }
    }

    /// Classifies text: color, link, JSON, CSV, markdown, code, else plain.
    static func textItem(_ text: String, lineLimit: Int = codeLineLimit) -> ClipPreviewItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isNewline), let color = ColorValueParser.parse(trimmed),
           color.literal == trimmed {
            return .color(color)
        }
        if let url = singleLink(trimmed) { return .link(url) }
        let window = String(text.prefix(classificationWindow))
        switch EditorLanguageSniffer.language(forText: window) {
        case .json: return .json(text)
        case .csv:
            if let table = CSVTable.preview(text) { return .csv(table) }
            return .text(text)
        case .markdown: return .markdown(text)
        case .plain:
            if let language = codeSnippetLanguage(trimmed) {
                let capped = capLines(text, limit: lineLimit)
                return .code(text: capped.text, language: language, truncatedLines: capped.dropped)
            }
            return .text(text)
        case let language:
            let capped = capLines(text, limit: lineLimit)
            return .code(text: capped.text, language: language, truncatedLines: capped.dropped)
        }
    }

    /// Language guess for a short statement the sniffer scores too low to call code (one `let` line),
    /// or nil when the text reads as prose. Needs a declaration keyword plus a call or assignment.
    static func codeSnippetLanguage(_ trimmed: String) -> CodeLanguage? {
        guard trimmed.count <= 2048 else { return nil }
        let starters: [(prefix: String, language: CodeLanguage)] = [
            ("let ", .swift), ("var ", .swift), ("func ", .swift), ("guard ", .swift),
            ("def ", .python), ("const ", .javascript), ("function ", .javascript),
        ]
        guard let match = starters.first(where: { trimmed.hasPrefix($0.prefix) }) else { return nil }
        let hasCall = trimmed.contains("(") && trimmed.contains(")")
        let hasAssign = trimmed.contains(" = ")
        guard (hasCall && hasAssign) || (hasCall && match.prefix == "func ") else { return nil }
        return match.language
    }

    /// Keeps at most `limit` lines; `dropped` is how many were removed.
    static func capLines(_ text: String, limit: Int) -> (text: String, dropped: Int) {
        let safeLimit = max(1, limit)
        var kept: [Substring] = []
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            total += 1
            if kept.count < safeLimit { kept.append(line) }
        }
        return (kept.joined(separator: "\n"), max(0, total - kept.count))
    }

    /// The URL when the whole text is exactly one http(s) link.
    static func singleLink(_ trimmed: String) -> URL? {
        guard !trimmed.isEmpty, trimmed.count <= 2048, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// Tile color, symbol and label for one clip, derived from the same classifier as the preview.
struct ClipVisualKind: Equatable {
    let style: ClipKindStyle
    let label: String
    let symbol: String
}

extension ClipKindStyle {
    /// SF Symbol for the kind tile.
    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "globe"
        case .email: return "envelope"
        case .color: return "paintpalette"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .richText: return "doc.richtext"
        }
    }
}

extension ClipPreviewProvider {
    /// Kind style, label and symbol for a non-sensitive clip. Uses only the in-memory clip text (the
    /// 300-character preview for text), never the database, so it is cheap enough for list rows.
    static func visual(for clip: Clip) -> ClipVisualKind {
        if clip.isImageLike { return ClipVisualKind(style: .image, label: "Image", symbol: ClipKindStyle.image.symbolName) }
        if clip.contentKind == .file { return ClipVisualKind(style: .file, label: "File", symbol: ClipKindStyle.file.symbolName) }
        switch clip.kind {
        case .email: return ClipVisualKind(style: .email, label: "Email", symbol: ClipKindStyle.email.symbolName)
        case .colorValue: return ClipVisualKind(style: .color, label: "Color", symbol: ClipKindStyle.color.symbolName)
        case .link: return ClipVisualKind(style: .link, label: "Link", symbol: ClipKindStyle.link.symbolName)
        case .filePath: return ClipVisualKind(style: .file, label: "File path", symbol: "folder")
        case .image, .file, .text: break
        }
        let item = textItem(clip.previewText)
        let style = item.kindStyle
        let label = style == .richText ? "Rich text" : item.kindLabel
        return ClipVisualKind(style: style, label: label, symbol: style.symbolName)
    }
}

extension ClipPreviewItem {
    /// Semantic kind style for tinting.
    var kindStyle: ClipKindStyle {
        switch self {
        case .masked, .text, .csv: return .text
        case .code, .json: return .code
        case .markdown: return .richText
        case .image: return .image
        case .file: return .file
        case .color: return .color
        case .link: return .link
        }
    }
}
