import Foundation

/// Query-grammar problems for the inline notice under the search field.
enum SearchWarnings {
    /// Human-readable warnings for `query`; empty for a clean query. Messages
    /// only echo tokens the user typed, never stored clip content.
    static func messages(for query: String, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        guard !query.isEmpty else { return [] }
        return ClipQueryParser.parse(query, now: now, calendar: calendar).warnings.map(\.message)
    }

    /// Tooltip describing the search grammar (see the header of ClipSearchQuery.swift).
    static let grammarHint = """
    Words match clip text; "quoted phrases" match exactly; -word or -"phrase" excludes. \
    kind:image|text|file|link|email|color|path, app:safari, in:Work (category), \
    before:2025-01-31, after:2025-01-01, on:2025-01-15, size:>1mb. \
    Shortcuts: #image #safari #today #2w. Prefix any filter with - to negate it.
    """
}
