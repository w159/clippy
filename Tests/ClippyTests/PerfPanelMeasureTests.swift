import GRDB
import XCTest
@testable import Clippy

/// Before/after numbers for panel lag. Each value prints as `PERFMEASURE <key> <value> <unit>` so CI logs can be
/// grepped. Assertions are generous safety bounds only; the printed numbers are the evidence.
private final class MeasureRunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor
final class PerfPanelMeasureTests: XCTestCase {
    private static let words = ["invoice", "meeting", "swift", "clipboard", "report", "budget", "error", "server",
                                "alpha", "bravo", "charlie", "delta", "quarterly", "review", "deploy", "token",
                                "network", "release", "kitchen", "garden", "window", "pencil", "orange", "harbor"]
    private static let seedCount = 5_000

    private func report(_ key: String, _ value: Double, _ unit: String) {
        print("PERFMEASURE \(key) \(String(format: "%.1f", value)) \(unit)")
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = (ContinuousClock.now - start).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// Spins the main run loop until `condition` holds; returns false on timeout.
    private func pump(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        return condition()
    }

    private func seededDatabase() throws -> ClipDatabase {
        let db = try makeTestDatabase(self)
        let now = Date()
        try db.dbQueue.write { conn in
            for index in 0..<Self.seedCount {
                var parts = (0..<8).map { Self.words[(index &* 31 &+ $0 &* 7) % Self.words.count] }
                if index % 40 == 0 { parts.append("foo-bar") }
                var clip = makeTextClip(parts.joined(separator: " ") + " #\(index)",
                                        createdAt: now.addingTimeInterval(-Double(index)))
                try clip.insert(conn)
            }
        }
        return db
    }

    private func makeStore() throws -> ClipStore {
        let store = ClipStore(database: try seededDatabase())
        XCTAssertTrue(pump { !store.clips.isEmpty }, "the observed window loaded")
        return store
    }

    private func awaitLanded(_ store: ClipStore) -> Bool {
        pump { !store.hasPendingSearch }
    }

    func testSearchLatencyOn5000Clips() throws {
        let store = try makeStore()
        var samples: [Double] = []
        for query in ["invoice", "quart", "invoice meeting", "foo-bar", "zzqxnomatch"] {
            store.query = ""
            XCTAssertTrue(awaitLanded(store))
            let start = ContinuousClock.now
            store.query = query
            XCTAssertTrue(awaitLanded(store), "search for \(query) landed")
            samples.append(milliseconds(since: start))
        }
        let result = median(samples)
        report("search.latency.5000.ms", result, "ms")
        XCTAssertLessThan(result, 1500, "median search latency (debounce included)")
    }

    func testSearchKeystrokesOn5000Clips() throws {
        let store = try makeStore()
        let typed = Array("invoic")
        for length in 1..<typed.count {
            store.query = String(typed[0..<length])
            pump(seconds: 0.06)
        }
        let start = ContinuousClock.now
        store.query = String(typed)
        XCTAssertTrue(awaitLanded(store), "final keystroke's results landed")
        let result = milliseconds(since: start)
        report("search.keystrokes.5000.ms", result, "ms")
        XCTAssertLessThan(result, 1500)
    }

    func testVisibleClipsOn5000Clips() throws {
        let store = try makeStore()
        let now = Date()
        store.clips = (0..<Self.seedCount).map { index in
            var clip = makeTextClip("clip \(Self.words[index % Self.words.count]) \(index)",
                                    createdAt: now.addingTimeInterval(-Double(index)))
            clip.id = Int64(index + 1)
            return clip
        }
        var samples: [Double] = []
        var shown = 0
        for _ in 0..<20 {
            let start = ContinuousClock.now
            shown = HistoryPanePolicy.visible(store.clips, query: store.query, isFiled: { store.isPinned($0) }).count
            samples.append(milliseconds(since: start))
        }
        XCTAssertEqual(shown, Self.seedCount)
        let result = median(samples)
        report("list.visibleClips.ms", result, "ms")
        XCTAssertLessThan(result, 500)

        // The memo behind ClipListView.clips(for:) answers repeat reads of the same inputs without refilling.
        let cache = VisibleClipsCache()
        XCTAssertNil(cache.lookup(selection: .history, query: "", version: 1))
        cache.store(store.clips, selection: .history, query: "", version: 1)
        XCTAssertEqual(cache.lookup(selection: .history, query: "", version: 1)?.count, Self.seedCount)
        XCTAssertNil(cache.lookup(selection: .history, query: "", version: 2), "a data change invalidates the memo")
        XCTAssertNil(cache.lookup(selection: .history, query: "a", version: 1), "a query change invalidates the memo")
        XCTAssertEqual(cache.missCount, 1)
    }

    func testPulseRefilterCount() throws {
        let store = try makeStore()
        store.query = "invoice"
        XCTAssertTrue(awaitLanded(store))
        let runs = MeasureRunCounter()
        store.searchRunner = { database, query, limit in
            runs.increment()
            return try database.searchClips(matching: query, limit: limit)
        }
        for number in 1...20 {
            var extra = makeTextClip("invoice pulse \(number)")
            extra.id = Int64(100_000 + number)
            store.recents = store.recents + [extra]
            pump(seconds: 0.1)
        }
        pump(seconds: 0.8)
        report("pulse.refilter.count", Double(runs.value), "runs")
        XCTAssertLessThanOrEqual(runs.value, 20, "pulses never run more searches than pulses")
    }
}
