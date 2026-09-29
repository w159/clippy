import XCTest
@testable import Clippy

final class ContextReaderStatsTests: XCTestCase {
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var stats = ContextReaderStats(clock: { [unowned self] in self.current })
    private let host = "com.example.slow"

    func testThreeConsecutiveTimeoutsSkipForTenMinutes() {
        stats.record(bundleID: host, elapsed: 0.3)
        stats.record(bundleID: host, elapsed: 0.5)
        XCTAssertFalse(stats.shouldSkip(bundleID: host))
        stats.record(bundleID: host, elapsed: 0.26)
        XCTAssertTrue(stats.shouldSkip(bundleID: host))
        XCTAssertFalse(stats.shouldSkip(bundleID: "com.example.other"))

        current.addTimeInterval(9 * 60)
        XCTAssertTrue(stats.shouldSkip(bundleID: host))
        current.addTimeInterval(61)
        XCTAssertFalse(stats.shouldSkip(bundleID: host), "skip expires after 10 minutes")
        // Streak restarts after expiry: one more slow read does not re-skip.
        stats.record(bundleID: host, elapsed: 0.4)
        XCTAssertFalse(stats.shouldSkip(bundleID: host))
    }

    func testFastReadResetsStreak() {
        stats.record(bundleID: host, elapsed: 0.3)
        stats.record(bundleID: host, elapsed: 0.3)
        stats.record(bundleID: host, elapsed: 0.02)
        stats.record(bundleID: host, elapsed: 0.3)
        XCTAssertFalse(stats.shouldSkip(bundleID: host))
        XCTAssertEqual(stats.snapshot().first?.consecutiveTimeouts, 1)
    }

    func testSnapshotReportsRollingWindow() {
        for _ in 0..<(ContextReaderStats.windowSize + 5) { stats.record(bundleID: host, elapsed: 0.1) }
        stats.record(bundleID: host, elapsed: 0.05)
        let row = stats.snapshot().first { $0.bundleID == host }
        XCTAssertEqual(row?.samples, ContextReaderStats.windowSize)
        XCTAssertEqual(row?.lastMillis, 50)
        XCTAssertEqual(row?.maxMillis, 100)
        XCTAssertNil(row?.skippedUntil)
    }

    func testSnapshotSortsSlowestFirstAndShowsSkip() {
        stats.record(bundleID: "fast", elapsed: 0.01)
        for _ in 0..<3 { stats.record(bundleID: host, elapsed: 0.4) }
        let rows = stats.snapshot()
        XCTAssertEqual(rows.map(\.bundleID), [host, "fast"])
        XCTAssertNotNil(rows.first?.skippedUntil)
        stats.reset()
        XCTAssertTrue(stats.snapshot().isEmpty)
    }
}
