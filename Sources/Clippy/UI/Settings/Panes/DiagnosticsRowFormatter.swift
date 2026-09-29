import Foundation

/// Display row for one context-reader host.
struct DiagnosticsRow: Equatable, Identifiable {
    let id: String
    let bundleID: String
    let averageText: String
    let timeoutsText: String
    let skippedText: String
    let isSkipped: Bool
}

/// Pure formatting of `ContextReaderStats.HostTiming` values.
enum DiagnosticsRowFormatter {
    /// Rows sorted slowest average first, then bundle id.
    static func rows(from timings: [ContextReaderStats.HostTiming], now: Date = Date()) -> [DiagnosticsRow] {
        timings
            .sorted { $0.averageMillis != $1.averageMillis ? $0.averageMillis > $1.averageMillis : $0.bundleID < $1.bundleID }
            .map { timing in
                let skipping = timing.skippedUntil.map { $0 > now } ?? false
                return DiagnosticsRow(
                    id: timing.bundleID,
                    bundleID: timing.bundleID,
                    averageText: "\(timing.averageMillis) ms",
                    timeoutsText: "\(timing.consecutiveTimeouts)",
                    skippedText: skipping ? skipText(until: timing.skippedUntil, now: now) : "No",
                    isSkipped: skipping)
            }
    }

    /// "Yes, 8 min left" style text.
    static func skipText(until: Date?, now: Date) -> String {
        guard let until, until > now else { return "No" }
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return "Yes, \(minutes) min left"
    }
}
