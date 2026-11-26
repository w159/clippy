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
        // Building a relative format style per row per redraw is slow. The text only
        // changes at minute-scale boundaries, so one result per date is reused for 10 s.
        let stamp = date.timeIntervalSinceReferenceDate
        let bucket = Int(reference.timeIntervalSinceReferenceDate / 10)
        let key = "\(stamp)-\(bucket)" as NSString
        if let hit = cache.object(forKey: key) { return hit as String }
        let text = date.formatted(
            Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow)
        )
        cache.setObject(text as NSString, forKey: key)
        return text
    }

    private static let cache = RelativeTimeCache()
}

/// NSCache is thread-safe and evicts under memory pressure, so the wrapper is Sendable.
private final class RelativeTimeCache: @unchecked Sendable {
    private let storage: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2000
        return cache
    }()

    func object(forKey key: NSString) -> NSString? { storage.object(forKey: key) }
    func setObject(_ value: NSString, forKey key: NSString) { storage.setObject(value, forKey: key) }
}
