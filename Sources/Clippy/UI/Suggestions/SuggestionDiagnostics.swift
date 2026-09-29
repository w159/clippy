import Foundation

/// Pure, text-free view of the last context capture for the Diagnostics popover
/// (ROADMAP INT-01 / INT-08). Built only from counts, durations and app names, so
/// neither the popover nor "Copy diagnostics" can leak screen text.
struct SuggestionDiagnostics: Equatable {
    /// Timing of the host that was captured, from `ContextReaderStats`.
    var host: ContextReaderStats.HostTiming?
    var capture: ContextCaptureLog.Entry?
    /// Reference time for the skip countdown.
    var now: Date

    /// Builds the diagnostics for the current capture and stats.
    init(
        capture: ContextCaptureLog.Entry?, timings: [ContextReaderStats.HostTiming], now: Date = Date()
    ) {
        self.capture = capture
        self.now = now
        host = capture?.bundleID.flatMap { id in timings.first { $0.bundleID == id } }
    }

    /// Live diagnostics from the shared log and stats.
    static func current(now: Date = Date()) -> SuggestionDiagnostics {
        SuggestionDiagnostics(
            capture: ContextCaptureLog.shared.last, timings: ContextReaderStats.shared.snapshot(), now: now)
    }

    /// True while the captured host is inside its skip window (INT-08).
    var isSkipped: Bool { (host?.skippedUntil ?? .distantPast) > now }

    /// Whole minutes left in the skip window, at least 1 while skipped.
    var skipMinutesRemaining: Int {
        guard let until = host?.skippedUntil, until > now else { return 0 }
        return max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Banner for a skipped host, e.g. "Skipped for 10 min: slow app". Nil otherwise.
    var skipMessage: String? {
        guard isSkipped else { return nil }
        return "Skipped for \(skipMinutesRemaining) min: slow app"
    }

    /// Display name of the captured app.
    var appName: String { capture?.appName ?? "Unknown app" }

    /// "Yes (412 characters)" / "No".
    var textReadLabel: String {
        guard let count = capture?.textCharacters, count > 0 else { return "No" }
        return "Yes (\(count) characters)"
    }

    /// Ordered label/value rows for the popover.
    var rows: [(label: String, value: String)] {
        guard let capture else { return [("Last capture", "None yet: open the panel in another app")] }
        var list: [(String, String)] = [
            ("App", appName),
            ("Text read", textReadLabel),
            ("Elapsed", "\(capture.elapsedMillis) ms"),
        ]
        if let host {
            list += [
                ("Samples", "\(host.samples)"),
                ("Average", "\(host.averageMillis) ms"),
                ("Slowest", "\(host.maxMillis) ms"),
                ("Timeouts in a row", "\(host.consecutiveTimeouts)"),
            ]
        }
        if let skipMessage { list.append(("Status", skipMessage)) }
        return list
    }

    /// Clipboard text: labels, counts and durations only, never screen text.
    var copyText: String {
        var lines = ["Clippy context diagnostics"]
        for row in rows { lines.append("\(row.label): \(row.value)") }
        if let bundle = capture?.bundleID { lines.append("Bundle: \(bundle)") }
        return lines.joined(separator: "\n")
    }
}
