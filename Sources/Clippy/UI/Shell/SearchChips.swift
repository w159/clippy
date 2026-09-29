import Foundation

/// Quick date ranges offered by the header's date chip.
enum SearchDatePreset: String, CaseIterable, Identifiable {
    case today, yesterday, week, month

    var id: String { rawValue }

    /// Chip label.
    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }

    /// Inclusive `after` and exclusive `before` bounds relative to `now`.
    func bounds(now: Date, calendar: Calendar) -> (after: Date, before: Date?) {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return (today, nil)
        case .yesterday:
            return (calendar.date(byAdding: .day, value: -1, to: today) ?? today, today)
        case .week: return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, nil)
        case .month: return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, nil)
        }
    }

    /// The preset whose bounds equal the filter's date range, if any.
    static func matching(_ filter: SearchFilter, now: Date, calendar: Calendar) -> SearchDatePreset? {
        guard let after = filter.after else { return nil }
        return allCases.first { preset in
            let bounds = preset.bounds(now: now, calendar: calendar)
            return bounds.after == calendar.startOfDay(for: after)
                && bounds.before == filter.before.map { calendar.startOfDay(for: $0) }
        }
    }
}

/// Pure query-string editing behind the header's filter chips. The query
/// string stays the source of truth: every operation parses it into a
/// `SearchFilter`, edits that, and writes it back with `SearchFilter.applied`,
/// which keeps free text, negations and sizes as typed.
struct SearchChipEditor {
    var now: Date = Date()
    var calendar: Calendar = .current
    var categoryID: (String) -> Int64? = { _ in nil }
    var categoryName: (Int64) -> String? = { _ in nil }
    /// Known app display names. The parser lowercases `app:` values, so chips
    /// resolve them back to these names (case-insensitive lookup).
    var appNames: [String] = []

    /// Filter part of `query`, with app names restored to display casing.
    func filter(of query: String) -> SearchFilter {
        var result = SearchFilter(parsing: query, now: now, calendar: calendar, categoryID: categoryID)
        let typed = Self.typedAppNames(in: query)
        result.apps = result.apps.map { app in
            appNames.first { $0.caseInsensitiveCompare(app) == .orderedSame }
                ?? typed.first { $0.caseInsensitiveCompare(app) == .orderedSame }
                ?? app
        }
        return result
    }

    /// Values of the positive `app:` tokens exactly as typed (quotes removed).
    static func typedAppNames(in query: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![-\w])app:("(?:[^"\\]|\\.)*"|\S+)"#,
                                                   options: [.caseInsensitive]) else { return [] }
        let range = NSRange(query.startIndex..., in: query)
        return regex.matches(in: query, range: range).compactMap { match in
            guard let value = Range(match.range(at: 1), in: query) else { return nil }
            var text = String(query[value])
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = String(text.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return text
        }
    }

    /// `query` with `filter` applied.
    func write(_ filter: SearchFilter, to query: String) -> String {
        filter.applied(to: query, now: now, calendar: calendar, categoryName: categoryName)
    }

    /// Adds `kind` to the query, or removes it when already present.
    func toggling(kind: ClipKindToken, in query: String) -> String {
        var current = filter(of: query)
        if current.kinds.contains(kind) { current.kinds.remove(kind) } else { current.kinds.insert(kind) }
        return write(current, to: query)
    }

    /// Adds or removes an `app:` filter (case-insensitive match on removal).
    func toggling(app: String, in query: String) -> String {
        var current = filter(of: query)
        if let index = current.apps.firstIndex(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            current.apps.remove(at: index)
        } else {
            current.apps.append(app)
        }
        return write(current, to: query)
    }

    /// Adds or removes an `in:` filter.
    func toggling(categoryID id: Int64, in query: String) -> String {
        var current = filter(of: query)
        if let index = current.categoryIDs.firstIndex(of: id) {
            current.categoryIDs.remove(at: index)
        } else {
            current.categoryIDs.append(id)
        }
        return write(current, to: query)
    }

    /// Sets the date range to `preset`, or clears it when it is already active.
    func setting(date preset: SearchDatePreset?, in query: String) -> String {
        var current = filter(of: query)
        if let preset, SearchDatePreset.matching(current, now: now, calendar: calendar) != preset {
            let bounds = preset.bounds(now: now, calendar: calendar)
            current.after = bounds.after
            current.before = bounds.before
        } else {
            current.after = nil
            current.before = nil
        }
        return write(current, to: query)
    }

    /// `query` without any chip-editable filter (free text is kept).
    func clearingFilters(in query: String) -> String {
        write(SearchFilter(), to: query)
    }
}
