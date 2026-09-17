import Foundation

/// Human-facing relative timestamps ("now", "2m ago") for clip cards and script rows.
///
/// `Date.RelativeFormatStyle` alone is wrong for freshly created records: it rounds
/// the interval toward zero and keeps the sign, so anything under half a second old
/// renders as "in 0s" - future tense, for something that just happened. A clip is
/// always a fraction of a second old the first time its card draws, so "in 0s" was
/// the default state of every new card.
enum RelativeTime {
    /// Anything inside the last minute is "now"; older values use the narrow
    /// relative style. Dates in the future (clock skew, an iCloud row written by a
    /// machine running fast) also read as "now" rather than counting down.
    static func string(for date: Date, relativeTo reference: Date = Date()) -> String {
        let secondsElapsed = reference.timeIntervalSince(date)
        if secondsElapsed < 60 { return "now" }
        return date.formatted(
            Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow)
        )
    }
}
