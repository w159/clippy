import GRDB
import XCTest
@testable import Clippy

/// Budgets are generous (CI noise); the printed numbers are the real signal.
final class PerfBenchmarkTests: XCTestCase {
    private static let words = ["invoice", "meeting", "swift", "clipboard", "report", "budget", "error", "server",
                                "alpha", "bravo", "charlie", "delta", "quarterly", "review", "deploy", "token"]

    private func seed(_ db: ClipDatabase, count: Int = 10_000) throws {
        let now = Date()
        try db.dbQueue.write { conn in
            for index in 0..<count {
                let body = (0..<40).map { Self.words[(index &* 31 &+ $0 &* 7) % Self.words.count] + "\(index % 97)" }
                    .joined(separator: " ")
                let big = index % 50 == 0 ? String(repeating: body + "\n", count: 60) : body
                let kind: ClipContentKind = index % 10 == 0 ? .image : .text
                var clip = Clip(
                    id: nil, contentText: big + " #\(index)", contentRTF: nil, contentHTML: nil,
                    typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: "com.test.app\(index % 8)",
                    sourceAppName: index % 3 == 0 ? "Xcode" : "Notes",
                    createdAt: now.addingTimeInterval(-Double(index)), contentKind: kind,
                    mediaFilename: kind == .image ? "img\(index).png" : nil,
                    thumbFilename: kind == .image ? "img\(index).png" : nil, byteSize: big.utf8.count)
                try clip.insert(conn)
            }
        }
    }

    private func ms(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<5 {
            let elapsed = try clock.measure(body)
            best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        print("PERF \(label): \(String(format: "%.2f", best)) ms (best of 5)")
        return best
    }

    func testBenchmarksOn10kClips() throws {
        let db = try makeTestDatabase(self)
        try seed(db)
        // Pin a few clips so the category branch of the list query is exercised.
        for id in stride(from: 5, through: 500, by: 50) { try db.toggleStarterMembership(clipID: Int64(id)) }

        let list = try ms("list fetch (ClipStore observation window)") {
            _ = try db.dbQueue.read { conn in
                try Clip.fetchAll(conn, sql: ClipDatabase.observationWindowSQL, arguments: [300])
            }
        }
        let search = try ms("FTS search 'invoice'") { _ = try db.search(matching: "invoice", limit: 300) }
        let search2 = try ms("FTS search 'quarterly review'") { _ = try db.search(matching: "quarterly review", limit: 300) }
        let kind = try ms("filter kind #image") { _ = try db.search(matching: "#image", limit: 300) }
        let app = try ms("filter app:xcode") { _ = try db.search(matching: "app:xcode", limit: 300) }
        let pin = try ms("pin toggle") { try db.toggleStarterMembership(clipID: 1234) }
        var counter = 0
        let insert = try ms("insert (dedupe+evict)") {
            counter += 1
            var clip = Clip(id: nil, contentText: "fresh clip \(counter) \(UUID())", contentRTF: nil, contentHTML: nil,
                            typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: nil, sourceAppName: "Notes",
                            createdAt: Date())
            try db.saveCapturedClip(&clip, cap: 10_000)
        }

        XCTAssertLessThan(list, 30, "10k-clip initial list fetch budget")
        XCTAssertLessThan(search, 50, "10k-clip FTS search budget")
        XCTAssertLessThan(search2, 50, "10k-clip multi-term search budget")
        XCTAssertLessThan(kind, 50, "10k-clip kind filter budget")
        XCTAssertLessThan(app, 50, "10k-clip app filter budget")
        XCTAssertLessThan(pin, 20, "10k-clip pin toggle budget")
        XCTAssertLessThan(insert, 30, "10k-clip insert budget")
    }
}
