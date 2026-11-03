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

    /// Rows shaped like real rich-text history: RTF and HTML blobs sit between the text
    /// and the title/OCR columns, so a scan that reads those columns walks overflow pages.
    private func seedRich(_ db: ClipDatabase, count: Int = 10_000) throws {
        let now = Date()
        let rtf = Data(repeating: 0x7B, count: 6_000)
        let html = Data(repeating: 0x3C, count: 6_000)
        try db.dbQueue.write { conn in
            for index in 0..<count {
                let body = (0..<40).map { Self.words[(index &* 31 &+ $0 &* 7) % Self.words.count] + "\(index % 97)" }
                    .joined(separator: " ")
                // One rare fragment, deep in the history, to force a full scan.
                let rare = index == count - 50 ? " xqzjvk" : ""
                var clip = Clip(
                    id: nil, contentText: body + " #\(index)" + rare, contentRTF: rtf, contentHTML: html,
                    typeIdentifier: "public.rtf", sourceAppBundleID: "com.test.app\(index % 8)",
                    sourceAppName: "Notes", createdAt: now.addingTimeInterval(-Double(index)))
                if index % 5 == 0 { clip.userTitle = "Title \(index)" }
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

    /// Search over rich-text rows: a plain word with plenty of whole-word matches must not pay for the
    /// fragment scan, and a rare fragment (full LIKE scan) must stay interactive.
    func testSearchBenchmarksOn10kRichTextClips() throws {
        let db = try makeTestDatabase(self)
        try seedRich(db)

        let word = try ms("rich: plain word 'invoice'") { XCTAssertEqual(try db.search(matching: "invoice", limit: 300).hits.count, 300) }
        let words = try ms("rich: two words 'quarterly review'") { _ = try db.search(matching: "quarterly review", limit: 300) }
        let commonFragment = try ms("rich: common fragment 'nvoic'") { XCTAssertEqual(try db.search(matching: "nvoic", limit: 300).hits.count, 300) }
        let rareFragment = try ms("rich: rare fragment 'qzjv'") { XCTAssertEqual(try db.search(matching: "qzjv", limit: 300).hits.count, 1) }
        let miss = try ms("rich: no match 'zqxjv'") { XCTAssertEqual(try db.search(matching: "zqxjv", limit: 300).hits.count, 0) }

        let slack = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 1.0 : 3.0
        XCTAssertLessThan(word, 100 * slack, "10k rich-text plain word budget")
        XCTAssertLessThan(words, 100 * slack, "10k rich-text two-word budget")
        XCTAssertLessThan(commonFragment, 100 * slack, "10k rich-text common fragment budget")
        XCTAssertLessThan(rareFragment, 250 * slack, "10k rich-text rare fragment (full scan) budget")
        XCTAssertLessThan(miss, 250 * slack, "10k rich-text no-match (full scan) budget")
    }

    func testBenchmarksOn10kClips() throws {
        let db = try makeTestDatabase(self)
        try seed(db)
        // Pin a few clips so the category branch of the list query is exercised.
        for id in stride(from: 5, through: 500, by: 50) { try db.toggleStarterMembership(clipID: Int64(id)) }

        // A fresh loader each round: the cold first load the panel pays on launch.
        let list = try ms("list fetch (ClipStore observation window)") {
            _ = try db.dbQueue.read { conn in
                try ClipWindowLoader().load(conn, limit: 300, generation: db.contentGeneration)
            }
        }
        let search = try ms("FTS search 'invoice'") { _ = try db.search(matching: "invoice", limit: 300) }
        let search2 = try ms("FTS search 'quarterly review'") { _ = try db.search(matching: "quarterly review", limit: 300) }
        // Fragment-only and no-match queries fall through the index to the LIKE
        // scan: the worst case for every keystroke.
        let fragment = try ms("fragment search 'nvoic'") { _ = try db.search(matching: "nvoic", limit: 300) }
        let miss = try ms("no-match search 'zqxjv'") { _ = try db.search(matching: "zqxjv", limit: 300) }
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

        // Shared CI runners are ~2x slower and noisy; local runs keep the strict budgets.
        let slack = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 1.0 : 3.0
        XCTAssertLessThan(list, 30 * slack, "10k-clip initial list fetch budget")
        XCTAssertLessThan(search, 50 * slack, "10k-clip FTS search budget")
        XCTAssertLessThan(search2, 50 * slack, "10k-clip multi-term search budget")
        XCTAssertLessThan(fragment, 100 * slack, "10k-clip fragment search budget")
        XCTAssertLessThan(miss, 100 * slack, "10k-clip no-match search budget")
        XCTAssertLessThan(kind, 50 * slack, "10k-clip kind filter budget")
        XCTAssertLessThan(app, 50 * slack, "10k-clip app filter budget")
        XCTAssertLessThan(pin, 20 * slack, "10k-clip pin toggle budget")
        XCTAssertLessThan(insert, 30 * slack, "10k-clip insert budget")
    }
}

/// Baselines for relaunch, capture, window memory and search at 50k clips. The printed
/// numbers are the signal; budgets are 5x+ the expected cost so CI noise does not flake.
extension PerfBenchmarkTests {
    private static let ciSlack = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 1.0 : 3.0

    /// What the app pays on every relaunch: `ClipDatabase.init` opens the on-disk file as a
    /// `DatabasePool` and runs the migrator (all migrations already applied).
    func testLaunchOpenAndMigrateOn50kClips() throws {
        let url: URL
        let media: URL
        do {
            let db = try makeTestDatabase(self)
            try seed(db, count: 50_000)
            url = db.databaseURL
            media = url.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
        }
        let open = try ms("launch: open+migrate 50k clips") {
            _ = try ClipDatabase(databaseURL: url, mediaDirectory: media)
        }
        let reopened = try ClipDatabase(databaseURL: url, mediaDirectory: media)
        XCTAssertEqual(try reopened.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clips") }, 50_000)
        XCTAssertLessThan(open, 1_500 * Self.ciSlack, "50k-clip relaunch open+migrate budget")
    }

    /// The text path of the clipboard monitor (`saveCapturedClip`) against a full history:
    /// a new unique clip (insert + dedupe lookup + eviction) and a duplicate (bump).
    func testCaptureInsertAndDuplicateOn50kClips() throws {
        let db = try makeTestDatabase(self)
        try seed(db, count: 50_000)

        var counter = 0
        let insert = try ms("capture insert at 50k") {
            counter += 1
            var clip = Clip(id: nil, contentText: "fresh clip \(counter) \(UUID())", contentRTF: nil, contentHTML: nil,
                            typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: nil, sourceAppName: "Notes",
                            createdAt: Date())
            XCTAssertTrue(try db.saveCapturedClip(&clip, cap: 50_000))
        }

        var first = makeTextClip("duplicate target at 50k")
        XCTAssertTrue(try db.saveCapturedClip(&first, cap: 50_000))
        let duplicate = try ms("capture duplicate at 50k") {
            var again = makeTextClip("duplicate target at 50k")
            XCTAssertFalse(try db.saveCapturedClip(&again, cap: 50_000))
        }

        XCTAssertLessThan(insert, 250 * Self.ciSlack, "50k-clip capture insert budget")
        XCTAssertLessThan(duplicate, 100 * Self.ciSlack, "50k-clip capture duplicate budget")
    }

    /// 3,000 filed rich clips (6,000-byte RTF and HTML each) plus 300 recents: what a full
    /// `ClipWindowLoader` load keeps resident.
    func testWindowMemoryWith3000FiledRichClips() throws {
        let db = try makeTestDatabase(self)
        let category = try db.createCategory(named: "Work", colorHex: "#154734", iconKind: .symbol, iconValue: "folder")
        let categoryID = try XCTUnwrap(category.id)
        let now = Date()
        let rtf = Data(repeating: 0x7B, count: 6_000)
        let html = Data(repeating: 0x3C, count: 6_000)
        try db.dbQueue.write { conn in
            for index in 0..<3_000 {
                var clip = Clip(
                    id: nil, contentText: "filed \(index)", contentRTF: rtf, contentHTML: html,
                    typeIdentifier: "public.rtf", sourceAppBundleID: nil, sourceAppName: "Notes",
                    createdAt: now.addingTimeInterval(-Double(100_000 + 3_000 - index)))
                try clip.insert(conn)
            }
            try conn.execute(
                sql: "INSERT INTO clip_category (clipID, categoryID, addedAt, sortOrder) SELECT id, ?, ?, id FROM clips",
                arguments: [categoryID, now])
            for index in 0..<300 {
                var clip = Clip(
                    id: nil, contentText: "recent \(index)", contentRTF: nil, contentHTML: nil,
                    typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: nil, sourceAppName: "Notes",
                    createdAt: now.addingTimeInterval(-Double(index)))
                try clip.insert(conn)
            }
        }

        let loader = ClipWindowLoader()
        let window = try db.dbQueue.read { try loader.load($0, limit: 300, generation: db.contentGeneration) }
        var bytes = 0
        for clip in window.clips {
            bytes += clip.contentText.utf8.count + (clip.contentRTF?.count ?? 0) + (clip.contentHTML?.count ?? 0)
            bytes += (clip.ocrText?.utf8.count ?? 0) + (clip.userTitle?.utf8.count ?? 0)
        }
        let megabytes = Double(bytes) / 1_048_576
        print(String(format: "PERF window memory, 3000 filed rich clips + recents: %.1f MB held (%d clips)",
                     megabytes, window.clips.count))
        XCTAssertEqual(window.clips.count, 3_300)
        XCTAssertGreaterThan(megabytes, 30, "the filed blobs are held by the window")
        XCTAssertLessThan(megabytes, 250, "window memory budget")
    }

    /// A cold first window load (fresh loader) on a 50k-clip history with 500 filed clips.
    func testWindowColdLoadOn50kClips() throws {
        let db = try makeTestDatabase(self)
        try seed(db, count: 50_000)
        let category = try db.createCategory(named: "Work", colorHex: "#154734", iconKind: .symbol, iconValue: "folder")
        let categoryID = try XCTUnwrap(category.id)
        let now = Date()
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: "INSERT INTO clip_category (clipID, categoryID, addedAt, sortOrder) SELECT id, ?, ?, id FROM clips WHERE id % 100 = 0",
                arguments: [categoryID, now])
        }

        var loaded = 0
        let cold = try ms("window cold load at 50k") {
            let window = try db.dbQueue.read { try ClipWindowLoader().load($0, limit: 300, generation: db.contentGeneration) }
            XCTAssertEqual(window.total, 50_000)
            loaded = window.clips.count
        }
        XCTAssertGreaterThanOrEqual(loaded, 500, "every filed clip is in the window")
        XCTAssertLessThan(cold, 500 * Self.ciSlack, "50k-clip cold window load budget")
    }

    /// Same rich rows as the 10k test (RTF and HTML blobs between text and title), at 50k.
    func testSearchBenchmarksOn50kRichTextClips() throws {
        let db = try makeTestDatabase(self)
        try seedRich(db, count: 50_000)

        let word = try ms("rich 50k: plain word 'invoice'") { XCTAssertEqual(try db.search(matching: "invoice", limit: 300).hits.count, 300) }
        let fragment = try ms("rich 50k: common fragment 'nvoic'") { XCTAssertEqual(try db.search(matching: "nvoic", limit: 300).hits.count, 300) }
        let miss = try ms("rich 50k: no match 'zqxjv'") { XCTAssertEqual(try db.search(matching: "zqxjv", limit: 300).hits.count, 0) }

        XCTAssertLessThan(word, 500 * Self.ciSlack, "50k rich-text plain word budget")
        XCTAssertLessThan(fragment, 500 * Self.ciSlack, "50k rich-text common fragment budget")
        XCTAssertLessThan(miss, 3_000 * Self.ciSlack, "50k rich-text no-match (full scan) budget")
    }
}
