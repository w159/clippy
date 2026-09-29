import Foundation

/// The chip-editable subset of a search query: kinds, apps, a created-date
/// range and categories. It reads from and writes to the query grammar
/// (ClipSearchQuery.swift), so filter chips edit the query string and the
/// string stays the single source of truth.
struct SearchFilter: Equatable {
    var kinds: Set<ClipKindToken> = []
    var apps: [String] = []
    /// Inclusive lower bound (day granularity when serialised).
    var after: Date?
    /// Exclusive upper bound (day granularity when serialised).
    var before: Date?
    var categoryIDs: [Int64] = []

    var isEmpty: Bool {
        kinds.isEmpty && apps.isEmpty && after == nil && before == nil && categoryIDs.isEmpty
    }

    init(kinds: Set<ClipKindToken> = [], apps: [String] = [], after: Date? = nil,
         before: Date? = nil, categoryIDs: [Int64] = []) {
        self.kinds = kinds
        self.apps = apps
        self.after = after
        self.before = before
        self.categoryIDs = categoryIDs
    }

    /// Extracts the filter part of `query`. `categoryID` resolves an `in:` name
    /// to an id; unresolved names are dropped.
    init(parsing query: String, now: Date = Date(), calendar: Calendar = .current,
         categoryID: (String) -> Int64? = { _ in nil }) {
        let parsed = ClipQueryParser.parse(query, now: now, calendar: calendar)
        self.init(kinds: parsed.kinds, apps: parsed.sourceApps, after: parsed.since, before: parsed.until,
                  categoryIDs: parsed.categories.compactMap(categoryID))
    }

    /// Filter tokens only, in canonical order, quoting values that need it.
    func tokens(calendar: Calendar = .current, categoryName: (Int64) -> String? = { _ in nil }) -> [String] {
        var out: [String] = []
        let kindList = kinds.map(\.rawValue).sorted()
        if !kindList.isEmpty { out.append("kind:" + kindList.joined(separator: ",")) }
        out.append(contentsOf: apps.map { "app:" + Self.quoted($0) })
        out.append(contentsOf: categoryIDs.compactMap(categoryName).map { "in:" + Self.quoted($0) })
        switch (after, before) {
        case let (start?, end?):
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            let from = Self.day(start, calendar), to = Self.day(last, calendar)
            out.append(from == to ? "on:\(from)" : "on:\(from)..\(to)")
        case let (start?, nil): out.append("after:" + Self.day(start, calendar))
        case let (nil, end?): out.append("before:" + Self.day(end, calendar))
        case (nil, nil): break
        }
        return out
    }

    /// The query string for this filter alone.
    func queryString(calendar: Calendar = .current, categoryName: (Int64) -> String? = { _ in nil }) -> String {
        tokens(calendar: calendar, categoryName: categoryName).joined(separator: " ")
    }

    /// `query` with its filter tokens replaced by this filter; free text,
    /// negations and sizes are kept as typed.
    func applied(to query: String, now: Date = Date(), calendar: Calendar = .current,
                 categoryName: (Int64) -> String? = { _ in nil }) -> String {
        let residual = ClipQueryParser.parse(query, now: now, calendar: calendar).residual
        return ([residual] + tokens(calendar: calendar, categoryName: categoryName))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }
}
