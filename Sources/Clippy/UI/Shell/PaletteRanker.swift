import Foundation

/// Fuzzy ranking for the command palette. Every whitespace-separated query
/// token must match the title, a keyword or the subtitle; scores add up.
/// Order of preference per token: exact > prefix > word prefix > substring >
/// subsequence (with bonuses for consecutive and word-start letters).
enum PaletteRanker {
    /// Enabled commands matching `query`, best first. An empty query returns
    /// every enabled command in its original order. Ties keep original order.
    /// With an empty query, `recents` (most recent first) are listed before the rest.
    static func rank(_ commands: [any PaletteCommand], query: String,
                     recents: [String] = []) -> [any PaletteCommand] {
        let enabled = commands.filter(\.isEnabled)
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return promoteRecents(enabled, recents: recents) }
        var scored: [(offset: Int, score: Int, command: any PaletteCommand)] = []
        for (offset, command) in enabled.enumerated() {
            if let total = score(command, tokens: tokens) {
                scored.append((offset, total, command))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return scored.map(\.command)
    }

    /// Moves commands whose id is in `recents` to the front, in recency order.
    static func promoteRecents(_ commands: [any PaletteCommand], recents: [String]) -> [any PaletteCommand] {
        guard !recents.isEmpty else { return commands }
        let byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let head = recents.compactMap { id -> (any PaletteCommand)? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return head + commands.filter { !seen.contains($0.id) }
    }

    /// Recents list after running `id`: newest first, unique, capped.
    static func pushRecent(_ id: String, into recents: [String], limit: Int = 4) -> [String] {
        Array(([id] + recents.filter { $0 != id }).prefix(limit))
    }

    /// Combined score for all tokens, nil when any token matches nowhere.
    static func score(_ command: any PaletteCommand, tokens: [String]) -> Int? {
        let title = normalize(command.title)
        let subtitle = command.subtitle.map(normalize)
        let keywords = command.keywords.map(normalize)
        var total = 0
        for token in tokens {
            var best: Int?
            if let value = matchScore(token, in: title) { best = value + 200 }
            for keyword in keywords {
                if let value = matchScore(token, in: keyword) { best = max(best ?? 0, value + 100) }
            }
            if let subtitle, let value = matchScore(token, in: subtitle) { best = max(best ?? 0, value) }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    /// Score of `needle` inside `haystack` (both already normalised), or nil.
    static func matchScore(_ needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }
        if haystack == needle { return 1_000 }
        if haystack.hasPrefix(needle) { return 800 - min(haystack.count - needle.count, 100) }
        if let range = haystack.range(of: needle) {
            let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let atWordStart = position == 0 || haystack[haystack.index(before: range.lowerBound)].isWhitespace
            return (atWordStart ? 600 : 400) - min(position, 100)
        }
        return subsequenceScore(needle, in: haystack)
    }

    /// Lowercased, diacritic-folded text.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func subsequenceScore(_ needle: String, in haystack: String) -> Int? {
        let hay = Array(haystack)
        var score = 200
        var index = 0
        var previous = -2
        for letter in needle {
            var found = false
            while index < hay.count {
                defer { index += 1 }
                guard hay[index] == letter else { continue }
                if index == previous + 1 { score += 12 }
                if index == 0 || hay[index - 1].isWhitespace { score += 15 }
                score -= min(index - max(previous, 0), 10)
                previous = index
                found = true
                break
            }
            if !found { return nil }
        }
        return max(score, 1)
    }
}
