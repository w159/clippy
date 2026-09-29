import Foundation

/// Pure helpers shared by the entity query, the intents and the Spotlight indexer.
enum IntentQueryMapper {
    /// Longest query accepted from Shortcuts/Spotlight.
    static let maxQueryLength = 500
    /// Most clips an intent will return.
    static let maxResults = 25

    /// Maps a free-text Shortcuts string onto the app's search grammar. The
    /// grammar (`#link`, `kind:`, `after:`, quotes) is passed through untouched;
    /// only whitespace, control characters and length are normalized.
    static func grammarQuery(from raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) }
        let collapsed = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxQueryLength))
    }

    /// Clamps a caller-supplied result limit to `1...maxResults`.
    static func clampedLimit(_ requested: Int?) -> Int {
        min(max(requested ?? 10, 1), maxResults)
    }

    /// Drops sensitive clips. `isSensitive` is injected so tests need no sidecar store.
    static func visible(_ clips: [Clip], isSensitive: (Clip) -> Bool) -> [Clip] {
        clips.filter { !isSensitive($0) }
    }

    /// Short title for entities and Spotlight: user title, else first line of text, else kind.
    static func title(for clip: Clip) -> String {
        if let title = clip.userTitle, !title.isEmpty { return title }
        switch clip.contentKind {
        case .text:
            let line = clip.previewText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "Text clip" : String(line.prefix(80))
        case .image: return "Image clip"
        case .file: return clip.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File clip"
        }
    }
}
