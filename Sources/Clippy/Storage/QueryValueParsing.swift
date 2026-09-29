import Foundation

/// A size bound from `size:` (bytes). Text clips use their UTF-8 length.
struct SizeConstraint: Equatable {
    enum Op: String { case lt = "<", le = "<=", gt = ">", ge = ">=", eq = "=" }
    var op: Op
    var bytes: Int

    /// `not (size op bytes)` expressed as a single constraint.
    var inverted: SizeConstraint {
        let flipped: Op
        switch op {
        case .lt: flipped = .ge
        case .le: flipped = .gt
        case .gt: flipped = .le
        case .ge: flipped = .lt
        case .eq: return self  // "not equal" has no single-constraint form; callers treat eq specially
        }
        return SizeConstraint(op: flipped, bytes: bytes)
    }

    func matches(_ size: Int) -> Bool {
        switch op {
        case .lt: return size < bytes
        case .le: return size <= bytes
        case .gt: return size > bytes
        case .ge: return size >= bytes
        case .eq: return size == bytes
        }
    }
}

/// A calendar span produced by a date value. `end` is exclusive; relative
/// durations (`3d`) are zero-width points.
struct QueryDateSpan: Equatable {
    var start: Date
    var end: Date
    var isRelative: Bool
}

/// Value parsers shared by `ClipQueryParser` (dates, durations, sizes).
enum QueryValues {
    /// Lower (and optional upper) bound for a `#duration` token. `nil` if `body`
    /// is not a duration, so the caller treats it as an app filter.
    static func relativeWindow(_ body: String, now: Date, calendar: Calendar) -> (since: Date, until: Date?)? {
        let startOfToday = calendar.startOfDay(for: now)
        if body == "today" { return (startOfToday, nil) }
        if body == "yesterday" {
            guard let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return nil }
            // #yesterday is yesterday only; it must not include today.
            return (start, startOfToday)
        }
        guard let point = relativePoint(body, now: now, calendar: calendar) else { return nil }
        return (point, nil)
    }

    /// `now` minus a duration like `2w`, `3d`, `month` (count defaults to 1).
    static func relativePoint(_ body: String, now: Date, calendar: Calendar) -> Date? {
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        let count = digits.isEmpty ? 1 : (Int(digits) ?? 1)
        let unit = String(body.dropFirst(digits.count))
        let component: Calendar.Component
        switch unit {
        case "d", "day", "days": component = .day
        case "w", "wk", "week", "weeks": component = .weekOfYear
        case "m", "mo", "month", "months": component = .month
        case "y", "yr", "year", "years": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -count, to: now)
    }

    /// Resolves a date operator value: `2025-06-01`, `2025-06`, `2025`, `today`,
    /// `yesterday`, or a relative duration.
    static func daySpan(_ raw: String, now: Date, calendar: Calendar) -> QueryDateSpan? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let startOfToday = calendar.startOfDay(for: now)
        if value == "today" {
            return calendar.date(byAdding: .day, value: 1, to: startOfToday)
                .map { QueryDateSpan(start: startOfToday, end: $0, isRelative: false) }
        }
        if value == "yesterday" {
            return calendar.date(byAdding: .day, value: -1, to: startOfToday)
                .map { QueryDateSpan(start: $0, end: startOfToday, isRelative: false) }
        }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            parts.first?.count == 4, parts.count <= 3, parts.dropFirst().allSatisfy({ $0.count <= 2 })
        {
            let numbers = parts.compactMap(Int.init)
            var components = DateComponents(year: numbers[0], month: numbers.count > 1 ? numbers[1] : 1,
                                            day: numbers.count > 2 ? numbers[2] : 1)
            components.hour = 0
            guard let start = calendar.date(from: components) else { return nil }
            // Reject wrapped dates such as 2025-02-31.
            let back = calendar.dateComponents([.year, .month, .day], from: start)
            guard back.year == components.year, back.month == components.month, back.day == components.day
            else { return nil }
            let unit: Calendar.Component = numbers.count == 1 ? .year : (numbers.count == 2 ? .month : .day)
            guard let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
            return QueryDateSpan(start: start, end: end, isRelative: false)
        }
        guard let point = relativePoint(value, now: now, calendar: calendar) else { return nil }
        return QueryDateSpan(start: point, end: point, isRelative: true)
    }

    /// `>10kb`, `<=1mb`, `500`, `=2k`, or a range `10kb..1mb`. Units are 1024-based.
    static func sizeConstraints(_ raw: String) -> [SizeConstraint]? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let range = value.range(of: "..") {
            let lower = String(value[..<range.lowerBound])
            let upper = String(value[range.upperBound...])
            guard let lowerBytes = bytes(lower), let upperBytes = bytes(upper), lowerBytes <= upperBytes else { return nil }
            return [SizeConstraint(op: .ge, bytes: lowerBytes), SizeConstraint(op: .le, bytes: upperBytes)]
        }
        var body = Substring(value)
        var comparison = SizeConstraint.Op.eq
        for candidate in [SizeConstraint.Op.le, .ge, .lt, .gt, .eq] where body.hasPrefix(candidate.rawValue) {
            comparison = candidate
            body = body.dropFirst(candidate.rawValue.count)
            break
        }
        guard let count = bytes(String(body)) else { return nil }
        return [SizeConstraint(op: comparison, bytes: count)]
    }

    private static func bytes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let numberPart = trimmed.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard !numberPart.isEmpty, let number = Double(numberPart), number >= 0, number.isFinite else { return nil }
        let multiplier: Double
        switch String(trimmed.dropFirst(numberPart.count)) {
        case "", "b": multiplier = 1
        case "k", "kb", "kib": multiplier = 1024
        case "m", "mb", "mib": multiplier = 1024 * 1024
        case "g", "gb", "gib": multiplier = 1024 * 1024 * 1024
        default: return nil
        }
        let total = number * multiplier
        guard total < Double(Int.max) / 2 else { return nil }
        return Int(total.rounded())
    }
}
