import Foundation

/// Per-host timing of `ContextReader.capture` (ROADMAP INT-08). Keeps a rolling
/// window of elapsed times per bundle id; a host that times out
/// `timeoutStreakLimit` times in a row is skipped for `skipDuration`. Holds only
/// bundle ids and durations, never screen text.
///
/// `@unchecked Sendable`: `hosts` is only touched under `lock`; `clock` is immutable.
final class ContextReaderStats: @unchecked Sendable {
    static let shared = ContextReaderStats()

    /// Diagnostics row for one host.
    struct HostTiming: Equatable {
        var bundleID: String
        var samples: Int
        var lastMillis: Int
        var averageMillis: Int
        var maxMillis: Int
        var consecutiveTimeouts: Int
        /// Non-nil while the host is being skipped.
        var skippedUntil: Date?
    }

    /// Rolling window length per host.
    static let windowSize = 20
    /// A read at least this long hit the AX messaging timeout.
    static let timeoutThreshold: TimeInterval = 0.25
    static let timeoutStreakLimit = 3
    static let skipDuration: TimeInterval = 10 * 60
    /// Bound on tracked hosts.
    private static let maxHosts = 64

    private struct Host {
        var samples: [TimeInterval] = []
        var streak = 0
        var skippedUntil: Date?
        var touched = Date.distantPast
    }

    private let clock: () -> Date
    private let lock = NSLock()
    private var hosts: [String: Host] = [:]

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    /// True while `bundleID` is in its skip window. An expired skip is cleared
    /// and the streak restarts so the host gets a fresh chance.
    func shouldSkip(bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var host = hosts[bundleID], let until = host.skippedUntil else { return false }
        if until > clock() { return true }
        host.skippedUntil = nil
        host.streak = 0
        hosts[bundleID] = host
        return false
    }

    /// Records one read and logs bundle id + millis only.
    func record(bundleID: String, elapsed: TimeInterval) {
        let now = clock()
        lock.lock()
        var host = hosts[bundleID] ?? Host()
        host.samples.append(elapsed)
        if host.samples.count > Self.windowSize { host.samples.removeFirst() }
        host.touched = now
        var skippedNow = false
        if elapsed >= Self.timeoutThreshold {
            host.streak += 1
            if host.streak >= Self.timeoutStreakLimit, host.skippedUntil == nil {
                host.skippedUntil = now.addingTimeInterval(Self.skipDuration)
                skippedNow = true
            }
        } else {
            host.streak = 0
        }
        hosts[bundleID] = host
        if hosts.count > Self.maxHosts,
            let oldest = hosts.min(by: { $0.value.touched < $1.value.touched })?.key
        {
            hosts.removeValue(forKey: oldest)
        }
        lock.unlock()
        let millis = Int(elapsed * 1000)
        ClippyLog.info("context read \(bundleID) \(millis)ms", category: ClippyLog.storage)
        if skippedNow {
            ClippyLog.info(
                "context read \(bundleID) skipped for \(Int(Self.skipDuration / 60)) min after repeated timeouts",
                category: ClippyLog.storage)
        }
    }

    /// Current per-host timings, slowest average first.
    func snapshot() -> [HostTiming] {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        return hosts.map { key, host in
            let millis = host.samples.map { Int($0 * 1000) }
            return HostTiming(
                bundleID: key, samples: millis.count, lastMillis: millis.last ?? 0,
                averageMillis: millis.isEmpty ? 0 : millis.reduce(0, +) / millis.count,
                maxMillis: millis.max() ?? 0, consecutiveTimeouts: host.streak,
                skippedUntil: host.skippedUntil.flatMap { $0 > now ? $0 : nil })
        }
        .sorted { $0.averageMillis > $1.averageMillis }
    }

    /// Forgets all timings (tests, diagnostics reset).
    func reset() {
        lock.lock(); hosts.removeAll(); lock.unlock()
    }
}
