import Foundation

// Pure search over every settings row (SET-09). No SwiftUI, no persistence.

/// One searchable settings row: which pane it lives in and the words that find it.
struct SettingsSearchEntry: Equatable, Identifiable {
    /// Stable row id, also used as the scroll/flash anchor inside the pane.
    let id: String
    /// Pane id (see `SettingsPaneID`).
    let pane: String
    /// Visible row title.
    let title: String
    /// Extra words that should find the row (synonyms, key names).
    let keywords: [String]

    init(id: String, pane: String, title: String, keywords: [String] = []) {
        self.id = id
        self.pane = pane
        self.title = title
        self.keywords = keywords
    }
}

/// A ranked hit; higher `score` sorts first.
struct SettingsSearchHit: Equatable, Identifiable {
    let entry: SettingsSearchEntry
    let score: Int
    var id: String { entry.id }
}

/// Ranks entries against a query: exact title, title prefix, word prefix in the
/// title, title substring, keyword match, then fuzzy subsequence of the title.
enum SettingsSearchIndex {
    /// Maximum hits returned so the results list stays scannable.
    static let resultLimit = 30

    /// Ranked hits for `query`; empty for a blank query. Ties keep source order.
    static func search(_ query: String, in entries: [SettingsSearchEntry]) -> [SettingsSearchHit] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        let tokens = needle.split(separator: " ").map(String.init)
        var hits: [SettingsSearchHit] = []
        for entry in entries {
            let score = tokens.reduce(into: 0) { total, token in
                guard total >= 0 else { return }
                let single = score(token: token, entry: entry)
                total = single == 0 ? -1 : total + single
            }
            if score > 0 { hits.append(SettingsSearchHit(entry: entry, score: score)) }
        }
        let indexed = hits.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }
        return indexed.prefix(resultLimit).map(\.element)
    }

    /// Lowercased, diacritic-folded, whitespace-collapsed text.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func score(token: String, entry: SettingsSearchEntry) -> Int {
        let title = normalize(entry.title)
        if title == token { return 100 }
        if title.hasPrefix(token) { return 80 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(token) }) { return 60 }
        if title.contains(token) { return 45 }
        if entry.keywords.map(normalize).contains(where: { $0 == token || $0.hasPrefix(token) || $0.contains(token) }) {
            return 30
        }
        return isSubsequence(token, of: title) && token.count >= 3 ? 10 : 0
    }

    private static func isSubsequence(_ token: String, of text: String) -> Bool {
        var remaining = token[...]
        for char in text where char == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
