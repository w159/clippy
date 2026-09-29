import Foundation
import GRDB

/// The single search-query parser. Turns the string typed in the search field
/// into a `ParsedQuery`; the database (`ClipDatabase.search`), the in-memory
/// category filter (`Clip.matchesLocally`) and highlighting (`SearchHighlight`)
/// all consume that one model.
///
/// # Grammar
/// Tokens are separated by whitespace and combine with AND unless noted.
///
///     word            free text, FTS5 prefix match ("inv" finds "invoice")
///     "exact phrase"  FTS5 phrase; `\"` and `\\` escape inside quotes
///     -word  -"phrase"  exclude clips containing it
///     kind:image      content kind (also `kind:image,link`); same names as `#kind`
///     app:chrome      source app name or bundle id (substring, case-insensitive)
///     app:"Visual Studio Code"
///     in:Work         member of the category with that name (case-insensitive)
///     after:2025-06-01   created on or after that day
///     before:2025-06-01  created before that day (that day excluded)
///     on:2025-06-01      created that day; also `on:2025-06`, `on:2025`
///     on:2025-06-01..2025-06-30   inclusive day range (`..B` / `A..` are open-ended)
///     size:>10kb  size:<=1mb  size:500  size:10kb..1mb   (units b/kb/mb/gb, 1024-based)
///     #image #text #file #link #email #color #path   legacy kind tokens
///     #today #yesterday #2weeks #3d #1m #1y #week      legacy duration tokens
///     #anything-else  legacy source-app token
///
/// Date values for `after:`/`before:` may also be `today`, `yesterday` or a
/// relative duration (`2w`, `3d`, `1m`, `1y`). Date semantics: `since` is
/// inclusive and `until` is exclusive. `#yesterday` is yesterday only; `#today`
/// and the `#Nunit` durations are open-ended up to now.
///
/// Negation works on words, phrases, kinds (`-#image`, `-kind:link`), apps
/// (`-app:chrome`), categories (`-in:Work`) and sizes (`-size:>1mb`). Negated
/// dates and negated `size:=` are unsupported and reported as warnings.
///
/// Escapes: `\-x` and `\#x` are literal words; `\:` keeps a colon literal.
/// An unknown `name:value` (such as `https://x`) is an ordinary word.
///
/// Malformed input never throws: the offending token is dropped and a
/// `QueryWarning` is appended to `ParsedQuery.warnings` so the UI can show it.
///
/// Precedence of `#tokens`: duration, then kind, then app. Multiple kind tokens
/// OR together, as do multiple app tokens and multiple `in:` categories.
///
/// Example: `invoice #edge #2weeks` -> text "invoice", app "edge", since two weeks ago.
/// Example: `"wire transfer" -draft kind:text after:2025-01-01 size:>1kb`.
struct ParsedQuery: Equatable {
    var text: String
    var sourceApps: [String]
    /// Inclusive lower bound on `createdAt`.
    var since: Date?
    var kinds: Set<ClipKindToken> = []
    /// Exclusive upper bound on `createdAt`.
    var until: Date? = nil
    var phrases: [String] = []
    var excludedTerms: [String] = []
    var excludedPhrases: [String] = []
    var excludedKinds: Set<ClipKindToken> = []
    var excludedApps: [String] = []
    /// Category names from `in:`.
    var categories: [String] = []
    var excludedCategories: [String] = []
    var sizeConstraints: [SizeConstraint] = []
    /// Non-fatal problems found while parsing; never contains clip content.
    var warnings: [QueryWarning] = []
    /// Tokens that `SearchFilter` does not model (words, phrases, negations,
    /// sizes), space-joined as typed. Lets filter chips rewrite a query in place.
    var residual: String = ""

    var isEmpty: Bool {
        text.isEmpty && phrases.isEmpty && sourceApps.isEmpty && since == nil && until == nil
            && kinds.isEmpty && excludedTerms.isEmpty && excludedPhrases.isEmpty && excludedKinds.isEmpty
            && excludedApps.isEmpty && categories.isEmpty && excludedCategories.isEmpty
            && sizeConstraints.isEmpty
    }

    /// Positive free-text needles (words then phrases), for highlighting and match location.
    var highlightTerms: [String] {
        text.split(separator: " ").map(String.init) + phrases
    }
}

/// Source-compatible name from before the grammar grew.
typealias ParsedClipQuery = ParsedQuery

/// A non-fatal query problem, shown to the user as a hint.
struct QueryWarning: Equatable {
    enum Kind: String {
        case unterminatedQuote, emptyOperatorValue, unknownKind, invalidDate, invalidSize
        case unsupportedNegation, unsearchableText, emptyDateRange, unknownCategory
    }

    let kind: Kind
    /// The offending token as the user typed it (never clip content).
    let token: String

    var message: String {
        switch kind {
        case .unterminatedQuote: return "Missing closing quote in \(token)"
        case .emptyOperatorValue: return "\(token) needs a value"
        case .unknownKind: return "Unknown kind in \(token)"
        case .invalidDate: return "Couldn't read the date in \(token)"
        case .invalidSize: return "Couldn't read the size in \(token)"
        case .unsupportedNegation: return "\(token) can't be negated"
        case .unsearchableText: return "\(token) has no searchable words and was ignored"
        case .emptyDateRange: return "The date range in your search matches nothing"
        case .unknownCategory: return "No category named \(token)"
        }
    }
}

/// A clip-kind filter named by a `#` token or `kind:`. `text`/`image`/`file` map
/// straight to the stored contentKind column; `link`/`email`/`color`/`path` are
/// derived from the text at render time (ClipKind.detect), so the database layer
/// narrows to text rows in SQL and finishes the match in Swift.
enum ClipKindToken: String, CaseIterable, Codable {
    case text, image, file, link, email, color, path

    init?(token: String) {
        switch token {
        case "text", "txt", "plaintext": self = .text
        case "image", "img", "photo", "picture", "screenshot": self = .image
        case "file", "files": self = .file
        case "link", "links", "url", "urls": self = .link
        case "email", "emails": self = .email
        case "color", "colors", "colour": self = .color
        case "path", "paths", "filepath": self = .path
        default: return nil
        }
    }

    /// The stored contentKind this token maps to. Derived kinds return .text
    /// because that is the stored kind their clips live under.
    var storedContentKind: ClipContentKind {
        switch self {
        case .image: return .image
        case .file: return .file
        case .text, .link, .email, .color, .path: return .text
        }
    }

    /// True when the token needs a Swift-side pass over ClipKind.detect after
    /// the SQL narrowing (the detection heuristics are not expressible in SQL).
    var isDerived: Bool {
        switch self {
        case .text, .image, .file: return false
        case .link, .email, .color, .path: return true
        }
    }

    /// Whether the given clip satisfies this kind filter.
    func matches(_ clip: Clip) -> Bool {
        switch self {
        case .text: return clip.contentKind == .text
        case .image: return clip.contentKind == .image
        case .file: return clip.contentKind == .file
        case .link: return clip.kind == .link
        case .email: return clip.kind == .email
        case .path: return clip.kind == .filePath
        case .color:
            if case .colorValue = clip.kind { return true }
            return false
        }
    }
}

enum ClipQueryParser {
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        var builder = Builder(now: now, calendar: calendar)
        for token in QueryTokenizer.tokens(in: raw) { builder.consume(token) }
        return builder.finish()
    }

    /// Accumulates tokens into a `ParsedQuery`.
    private struct Builder {
        let now: Date
        let calendar: Calendar
        var query = ParsedQuery(text: "", sourceApps: [], since: nil)
        var words: [String] = []
        var residual: [String] = []
        // `#duration` tokens keep the widest window; operators intersect.
        var durationSince: Date?
        var durationUntil: Date??
        var opSince: Date?
        var opUntil: Date?

        init(now: Date, calendar: Calendar) {
            self.now = now
            self.calendar = calendar
        }

        mutating func warn(_ kind: QueryWarning.Kind, _ token: QueryToken) {
            query.warnings.append(QueryWarning(kind: kind, token: token.source))
        }

        mutating func consume(_ token: QueryToken) {
            switch token.body {
            case .word(let word): consumeWord(word, token)
            case .phrase(let phrase, let terminated): consumePhrase(phrase, terminated, token)
            case .hash(let body): consumeHash(body.lowercased(), token)
            case .op(let name, let value): consumeOperator(name, value, token)
            }
        }

        private mutating func consumeWord(_ word: String, _ token: QueryToken) {
            guard !word.isEmpty else { return }
            residual.append(token.source)
            if FTS5Pattern(matchingAllPrefixesIn: word) == nil { warn(.unsearchableText, token) }
            if token.negated { query.excludedTerms.append(word) } else { words.append(word) }
        }

        private mutating func consumePhrase(_ phrase: String, _ terminated: Bool, _ token: QueryToken) {
            if !terminated { warn(.unterminatedQuote, token) }
            guard !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            residual.append(token.source)
            guard FTS5Pattern(matchingPhrase: phrase) != nil else {
                warn(.unsearchableText, token)
                return
            }
            if token.negated { query.excludedPhrases.append(phrase) } else { query.phrases.append(phrase) }
        }

        private mutating func consumeHash(_ body: String, _ token: QueryToken) {
            if let window = QueryValues.relativeWindow(body, now: now, calendar: calendar) {
                guard !token.negated else { return warn(.unsupportedNegation, token) }
                durationSince = Swift.min(durationSince ?? window.since, window.since)
                // Any open-ended window makes the union open-ended.
                switch durationUntil {
                case .none: durationUntil = .some(window.until)
                case .some(let existing):
                    if let existing, let new = window.until { durationUntil = .some(Swift.max(existing, new)) }
                    else { durationUntil = .some(nil) }
                }
            } else if let kind = ClipKindToken(token: body) {
                if token.negated {
                    query.excludedKinds.insert(kind)
                    residual.append(token.source)
                } else {
                    query.kinds.insert(kind)
                }
            } else if token.negated {
                query.excludedApps.append(body)
                residual.append(token.source)
            } else {
                query.sourceApps.append(body)
            }
        }

        private mutating func consumeOperator(_ name: String, _ value: String, _ token: QueryToken) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return warn(.emptyOperatorValue, token) }
            switch name {
            case "kind": consumeKinds(trimmed, token)
            case "app":
                if token.negated {
                    query.excludedApps.append(trimmed.lowercased())
                    residual.append(token.source)
                } else {
                    query.sourceApps.append(trimmed.lowercased())
                }
            case "in":
                if token.negated {
                    query.excludedCategories.append(trimmed)
                    residual.append(token.source)
                } else {
                    query.categories.append(trimmed)
                }
            case "size": consumeSize(trimmed, token)
            default: consumeDate(name, trimmed, token)
            }
        }

        private mutating func consumeKinds(_ value: String, _ token: QueryToken) {
            let parts = value.lowercased().split(separator: ",").map(String.init)
            let kinds = parts.compactMap { ClipKindToken(token: $0) }
            guard kinds.count == parts.count, !kinds.isEmpty else { return warn(.unknownKind, token) }
            if token.negated {
                query.excludedKinds.formUnion(kinds)
                residual.append(token.source)
            } else {
                query.kinds.formUnion(kinds)
            }
        }

        private mutating func consumeSize(_ value: String, _ token: QueryToken) {
            guard var constraints = QueryValues.sizeConstraints(value) else { return warn(.invalidSize, token) }
            if token.negated {
                // Only single inequality constraints invert cleanly.
                guard constraints.count == 1, constraints[0].op != .eq else {
                    return warn(.unsupportedNegation, token)
                }
                constraints = [constraints[0].inverted]
            }
            query.sizeConstraints.append(contentsOf: constraints)
            residual.append(token.source)
        }

        private mutating func consumeDate(_ name: String, _ value: String, _ token: QueryToken) {
            guard !token.negated else { return warn(.unsupportedNegation, token) }
            let lowered = value.lowercased()
            if let dots = lowered.range(of: "..") {
                guard name == "on" else { return warn(.invalidDate, token) }
                let lhs = String(lowered[..<dots.lowerBound])
                let rhs = String(lowered[dots.upperBound...])
                guard !(lhs.isEmpty && rhs.isEmpty) else { return warn(.invalidDate, token) }
                var start: Date?
                var end: Date?
                if !lhs.isEmpty {
                    guard let span = QueryValues.daySpan(lhs, now: now, calendar: calendar), !span.isRelative
                    else { return warn(.invalidDate, token) }
                    start = span.start
                }
                if !rhs.isEmpty {
                    guard let span = QueryValues.daySpan(rhs, now: now, calendar: calendar), !span.isRelative
                    else { return warn(.invalidDate, token) }
                    end = span.end
                }
                narrow(since: start, until: end)
                return
            }
            guard let span = QueryValues.daySpan(lowered, now: now, calendar: calendar) else {
                return warn(.invalidDate, token)
            }
            switch name {
            case "after": narrow(since: span.start, until: nil)
            case "before": narrow(since: nil, until: span.start)
            default:  // on
                guard !span.isRelative else { return warn(.invalidDate, token) }
                narrow(since: span.start, until: span.end)
            }
        }

        private mutating func narrow(since: Date?, until: Date?) {
            if let since { opSince = Swift.max(opSince ?? since, since) }
            if let until { opUntil = Swift.min(opUntil ?? until, until) }
        }

        mutating func finish() -> ParsedQuery {
            var since = durationSince
            if let opSince { since = Swift.max(since ?? opSince, opSince) }
            var until: Date?
            if case .some(let bound) = durationUntil { until = bound }
            if let opUntil { until = Swift.min(until ?? opUntil, opUntil) }
            if let since, let until, since >= until {
                query.warnings.append(QueryWarning(kind: .emptyDateRange, token: ""))
            }
            query.since = since
            query.until = until
            query.text = words.joined(separator: " ")
            query.residual = residual.joined(separator: " ")
            return query
        }
    }
}
