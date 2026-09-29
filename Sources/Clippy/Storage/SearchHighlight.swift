import Foundation

/// Where in a clip a search hit matched. `.ocr` marks clips found only through
/// their recognised image text so the UI can say so.
enum SearchMatchLocation: String, Equatable {
    case text, title, ocr
}

/// Pure helpers for marking search matches in result text.
enum SearchHighlight {
    /// Ranges of `text` that match the positive free-text words and phrases of
    /// `query`, case- and diacritic-insensitive, sorted and merged so they never
    /// overlap. Operators, negations and filters are ignored. Ranges are valid
    /// indices into `text` (Unicode-safe: composed and decomposed forms match).
    static func ranges(in text: String, for query: String, limit: Int = 200) -> [Range<String.Index>] {
        ranges(in: text, for: ClipQueryParser.parse(query), limit: limit)
    }

    /// Same as `ranges(in:for:)` for an already parsed query.
    static func ranges(in text: String, for parsed: ParsedQuery, limit: Int = 200) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for needle in parsed.highlightTerms where !needle.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, found.count < limit * 4,
                let hit = text.range(
                    of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<text.endIndex)
            {
                found.append(hit)
                searchStart = hit.upperBound > hit.lowerBound ? hit.upperBound : text.index(after: hit.lowerBound)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return Array(merged.prefix(limit))
    }

    /// Case- and diacritic-insensitive containment.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        needle.isEmpty || haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
