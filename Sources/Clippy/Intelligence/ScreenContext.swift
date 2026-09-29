import Foundation

/// Snapshot of what the frontmost app is showing, used to rank clipboard
/// history. Lives in memory only: `text` is never logged or persisted, and the
/// panel drops the whole context when it hides.
struct ScreenContext: Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var documentURL: String?
    /// Visible/selected text from the focused element, truncated. NEVER logged or persisted.
    var text: String
    var capturedAt: Date

    init(
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        documentURL: String? = nil,
        text: String = "",
        capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.text = text
        self.capturedAt = capturedAt
    }

    /// True when there is nothing usable (no text, title, or URL).
    var isEmpty: Bool {
        Self.clean(text) == nil && Self.clean(windowTitle) == nil && Self.clean(documentURL) == nil
    }

    /// Text used for embedding: title + document host/path + text, joined.
    var queryText: String {
        var pieces: [String] = []
        if let title = Self.clean(windowTitle) { pieces.append(title) }
        if let url = Self.clean(documentURL) { pieces.append(Self.urlWords(url)) }
        if let body = Self.clean(text) { pieces.append(body) }
        return String(pieces.joined(separator: "\n").prefix(Self.maxQueryChars))
    }

    /// Upper bound on `queryText` length, keeping embedding input small.
    static let maxQueryChars = 2000

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// "https://a.com/b/c-d.html" -> "a.com b c d html".
    private static func urlWords(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else { return raw }
        let separators = CharacterSet(charactersIn: "/-_.+%")
        let pathWords = url.path.components(separatedBy: separators).filter { !$0.isEmpty }
        return ([host] + pathWords).joined(separator: " ")
    }
}
