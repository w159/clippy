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
        case .plain: return .text(text)
        case let language:
            let capped = capLines(text, limit: lineLimit)
            return .code(text: capped.text, language: language, truncatedLines: capped.dropped)
        }
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
