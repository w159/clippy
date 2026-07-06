import Foundation

/// A clip search query split into its parts: free text for full-text search,
/// `#` kind filters, `#` source-app filters, and a `#`-duration lower bound on
/// the clip date.
///
/// Grammar (tokens are space separated, order independent):
///   - `#today`, `#yesterday`            -> since the start of that day
///   - `#2weeks`, `#2w`, `#3d`, `#1m`, `#1y`, `#week`, `#month`, `#year`
///                                        -> since now minus that span (count defaults to 1)
///   - `#image`, `#text`, `#file`, `#link`, `#email`, `#color`, `#path`
///     (plus aliases like `#img`, `#url`) -> match the clip's content kind
///   - any other `#token`                -> match the source app name or bundle id (substring)
///   - everything else                   -> free text, matched with FTS5
///
/// Token precedence: duration, then kind, then app. Multiple kind tokens OR
/// together, mirroring how multiple app tokens behave.
///
/// Example: `invoice #edge #2weeks` -> text "invoice", app "edge", since two weeks ago.
/// Example: `#image #today` -> every image captured today.
struct ParsedClipQuery: Equatable {
    var text: String
    var sourceApps: [String]
    var since: Date?
    var kinds: Set<ClipKindToken> = []

    var isEmpty: Bool { text.isEmpty && sourceApps.isEmpty && since == nil && kinds.isEmpty }
}

/// A clip-kind filter named by a `#` token. `text`/`image`/`file` map straight
/// to the stored contentKind column; `link`/`email`/`color`/`path` are derived
/// from the text at render time (ClipKind.detect), so the database layer
/// narrows to text rows in SQL and finishes the match in Swift.
enum ClipKindToken: String, CaseIterable {
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
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedClipQuery {
        var apps: [String] = []
        var since: Date?
        var kinds: Set<ClipKindToken> = []
        var textParts: [String] = []

        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard token.hasPrefix("#"), token.count > 1 else {
                textParts.append(String(token))
                continue
            }
            let body = String(token.dropFirst()).lowercased()
            if let date = relativeDate(body, now: now, calendar: calendar) {
                // Keep the widest window if several date tokens are given.
                since = Swift.min(since ?? date, date)
            } else if let kind = ClipKindToken(token: body) {
                kinds.insert(kind)
            } else {
                apps.append(body)
            }
        }

        return ParsedClipQuery(
            text: textParts.joined(separator: " "),
            sourceApps: apps,
            since: since,
            kinds: kinds
        )
    }

    /// Returns a lower-bound date for a duration token, or nil if the token is
    /// not a recognized duration (so the caller treats it as an app filter).
    private static func relativeDate(_ body: String, now: Date, calendar: Calendar) -> Date? {
        if body == "today" { return calendar.startOfDay(for: now) }
        if body == "yesterday" {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        }

        // Split a leading count (default 1) from the unit, e.g. "2weeks" -> 2,"weeks".
        let digits = body.prefix { $0.isNumber }
        let count = digits.isEmpty ? 1 : (Int(digits) ?? 1)
        let unit = String(body.dropFirst(digits.count))

        let component: Calendar.Component
        switch unit {
        case "d", "day", "days":        component = .day
        case "w", "wk", "week", "weeks": component = .weekOfYear
        case "m", "mo", "month", "months": component = .month
        case "y", "yr", "year", "years": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -count, to: now)
    }
}
