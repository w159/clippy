import Foundation

/// Pure date-bucketing for the history timeline: maps a clip date to the
/// section title it belongs to. Checks run finest-first (day, then week, then
/// month) so the result is monotonic as dates descend: clips sorted
/// newest-first never produce an out-of-order or duplicated section.
struct TimelineBucket {
    /// Cached formatters: sections recompute on every view update, so building
    /// a DateFormatter per clip would be wasteful.
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "MMMM"; return formatter
    }()
    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "MMMM yyyy"; return formatter
    }()

    /// Section title for `date` relative to `now`.
    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        // Week buckets precede month buckets.
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) {
            if thisWeek.contains(date) { return "This Week" }
            if let lastWeekDay = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
               let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekDay),
               lastWeek.contains(date) { return "Last Week" }
        }
        // Month buckets.
        if let thisMonth = calendar.dateInterval(of: .month, for: now) {
            if thisMonth.contains(date) { return "This Month" }
            if let lastMonthDay = calendar.date(byAdding: .month, value: -1, to: now),
               let lastMonth = calendar.dateInterval(of: .month, for: lastMonthDay),
               lastMonth.contains(date) { return "Last Month" }
        }
        // Older clips: month name, with the year appended outside the current year.
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthFormatter.string(from: date)
        }
        return monthYearFormatter.string(from: date)
    }
}
