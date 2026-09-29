import GRDB
import XCTest
@testable import Clippy

final class SearchDatabaseTests: XCTestCase {
    private func clip(_ text: String, app: String = "Notes", kind: ClipContentKind = .text,
                      at date: Date = Date(), media: String? = nil, size: Int? = nil) -> Clip {
        Clip(id: nil, contentText: text, contentRTF: nil, contentHTML: nil,
             typeIdentifier: kind == .image ? "public.png" : "public.utf8-plain-text",
             sourceAppBundleID: "com.test.\(app.lowercased())", sourceAppName: app, createdAt: date,
             contentKind: kind, mediaFilename: media, thumbFilename: media, byteSize: size)
    }

    @discardableResult
    private func add(_ db: ClipDatabase, _ clip: Clip) throws -> Int64 {
        var copy = clip
        switch clip.contentKind {
        case .image: try db.saveCapturedImageClip(&copy, cap: 1000)
        default: try db.saveCapturedClip(&copy, cap: 1000)
        }
        return try db.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM clips")! }
    }

    private func texts(_ db: ClipDatabase, _ query: String, limit: Int = 50) throws -> [String] {
        try db.search(matching: query, limit: limit).clips.map(\.contentText)
    }

    func testPhraseNegationAndAppOperators() throws {
        let db = try makeTestDatabase(self)
        try add(db, clip("wire transfer approved", app: "Mail"))
        try add(db, clip("transfer wire draft", app: "Notes"))
        try add(db, clip("wire transfer draft", app: "Notes"))
        XCTAssertEqual(Set(try texts(db, "\"wire transfer\"")), ["wire transfer approved", "wire transfer draft"])
        XCTAssertEqual(try texts(db, "wire -draft"), ["wire transfer approved"])
        XCTAssertEqual(try texts(db, "-draft"), ["wire transfer approved"])
        XCTAssertEqual(try texts(db, "app:mail"), ["wire transfer approved"])
        XCTAssertEqual(Set(try texts(db, "-app:mail")).count, 2)
        // The phrase "transfer draft" only occurs contiguously in "wire transfer draft".
        XCTAssertEqual(Set(try texts(db, "wire -\"transfer draft\"")),
                       ["wire transfer approved", "transfer wire draft"])
    }

    func testDateAndSizeOperators() throws {
        let db = try makeTestDatabase(self)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let d1 = calendar.date(from: DateComponents(year: 2025, month: 6, day: 1, hour: 10))!
        let d2 = calendar.date(from: DateComponents(year: 2025, month: 6, day: 2, hour: 10))!
        try add(db, clip("small one", at: d1))
        try add(db, clip(String(repeating: "x", count: 3000) + " big", at: d2))
        let now = calendar.date(from: DateComponents(year: 2025, month: 6, day: 10))!
        func run(_ q: String) throws -> Int {
            try db.search(matching: q, limit: 10, now: now, calendar: calendar).hits.count
        }
        XCTAssertEqual(try run("on:2025-06-01"), 1)
        XCTAssertEqual(try run("after:2025-06-02"), 1)
        XCTAssertEqual(try run("before:2025-06-02"), 1)
        XCTAssertEqual(try run("size:>1kb"), 1)
        XCTAssertEqual(try run("size:<1kb"), 1)
        XCTAssertEqual(try run("-size:>1kb"), 1)
        XCTAssertEqual(try run("#yesterday"), 0)
    }

    func testYesterdayDoesNotIncludeToday() throws {
        let db = try makeTestDatabase(self)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        try add(db, clip("today clip", at: today.addingTimeInterval(60)))
        try add(db, clip("yesterday clip", at: today.addingTimeInterval(-3600)))
        XCTAssertEqual(try texts(db, "#yesterday"), ["yesterday clip"])
    }

    func testCategoryOperatorAndUnknownCategoryWarning() throws {
        let db = try makeTestDatabase(self)
        let id = try add(db, clip("filed"))
        try add(db, clip("loose"))
        let cat = try db.createCategory(named: "Work", colorHex: "#FF0000", iconKind: .symbol, iconValue: "star")
        try db.setClip(id, inCategory: cat.id!, true)
        XCTAssertEqual(try texts(db, "in:work"), ["filed"])
        XCTAssertEqual(try texts(db, "-in:Work"), ["loose"])
        let outcome = try db.search(matching: "in:Nope", limit: 10)
        XCTAssertTrue(outcome.hits.isEmpty)
        XCTAssertEqual(outcome.warnings.map(\.kind), [.unknownCategory])
    }

    func testDerivedKindPagesUntilLimit() throws {
        let db = try makeTestDatabase(self)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 3 links buried under 900 newer plain-text clips.
        for i in 0..<3 { try add(db, clip("https://example.com/\(i)", at: base.addingTimeInterval(Double(i)))) }
        try db.dbQueue.write { conn in
            for i in 0..<900 {
                try conn.execute(sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                    VALUES (?, 'public.utf8-plain-text', ?, 'text')
                    """, arguments: ["plain \(i)", base.addingTimeInterval(1000 + Double(i))])
            }
        }
        XCTAssertEqual(try texts(db, "#link", limit: 3).count, 3)
        XCTAssertEqual(try texts(db, "kind:link -#email", limit: 10).count, 3)
        XCTAssertEqual(try texts(db, "-#link plain", limit: 5).count, 5)
    }

    func testUnusableTextProducesWarningAndRecentFallback() throws {
        let db = try makeTestDatabase(self)
        try add(db, clip("hello"))
        let outcome = try db.search(matching: "!!!", limit: 5)
        XCTAssertEqual(outcome.warnings.map(\.kind), [.unsearchableText])
        XCTAssertEqual(outcome.hits.count, 1)
    }

    // MARK: - OCR text + FTS triggers

    func testOCRTextIndexedAcrossInsertUpdateDelete() throws {
        let db = try makeTestDatabase(self)
        let id = try add(db, clip("", kind: .image, media: "img1.png"))
        XCTAssertTrue(try texts(db, "quarterly").isEmpty)
        try db.setOCRText(id: id, text: "Quarterly revenue report")
        let hit = try db.search(matching: "quarterly", limit: 5).hits
        XCTAssertEqual(hit.map(\.matchedIn), [.ocr])
        // Update replaces the indexed text.
        try db.setOCRText(id: id, text: "Something else")
        XCTAssertTrue(try texts(db, "quarterly").isEmpty)
        XCTAssertEqual(try db.search(matching: "else", limit: 5).hits.count, 1)
        // Editing the image resets the text.
        try db.dbQueue.write { try $0.execute(sql: "UPDATE clips SET ocrText = NULL WHERE id = ?", arguments: [id]) }
        XCTAssertTrue(try texts(db, "else").isEmpty)
        try db.setOCRText(id: id, text: "gone soon")
        try db.deleteClip(id: id)
        XCTAssertTrue(try texts(db, "gone").isEmpty)
        try db.dbQueue.read { conn in
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM clips_fts WHERE clips_fts MATCH 'gone'"), 0)
        }
    }

    func testTextMatchIsNotMarkedOCR() throws {
        let db = try makeTestDatabase(self)
        let id = try add(db, clip("invoice text", kind: .text))
        try db.setOCRText(id: id, text: "other")
        XCTAssertEqual(try db.search(matching: "invoice", limit: 5).hits.map(\.matchedIn), [.text])
    }

    func testClipsNeedingOCRCursorAndEmptyMarker() throws {
        let db = try makeTestDatabase(self)
        let a = try add(db, clip("", kind: .image, media: "a.png"))
        let b = try add(db, clip("", kind: .image, media: "b.png"))
        try add(db, clip("plain"))
        XCTAssertEqual(try db.clipsNeedingOCR(limit: 10).compactMap(\.id), [b, a])
        XCTAssertEqual(try db.clipsNeedingOCR(before: b, limit: 10).compactMap(\.id), [a])
        try db.setOCRText(id: b, text: "")
        XCTAssertEqual(try db.clipsNeedingOCR(limit: 10).compactMap(\.id), [a])
    }

    // MARK: - Migration

    func testMigrationFromV8KeepsDataAndBuildsOCRIndex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(old, upTo: "v8-clip-category-sort-repair")
        try old.write { conn in
            try conn.execute(sql: """
                INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind, userTitle)
                VALUES ('legacy invoice', 'public.utf8-plain-text', ?, 'text', 'Old title')
                """, arguments: [Date()])
        }
        XCTAssertFalse(try old.read { try $0.tableExists("smart_collections") })
        try old.close()

        let db = try ClipDatabase(databaseURL: url, mediaDirectory: dir.appendingPathComponent("media"))
        try db.dbQueue.read { conn in
            XCTAssertTrue(try conn.columns(in: "clips").contains { $0.name == "ocrText" })
            XCTAssertTrue(try conn.tableExists("smart_collections"))
        }
        // Existing rows are searchable by text and title after the FTS rebuild.
        XCTAssertEqual(try texts(db, "legacy"), ["legacy invoice"])
        XCTAssertEqual(try texts(db, "old"), ["legacy invoice"])
        let id = try XCTUnwrap(try db.allClips().first?.id)
        try db.setOCRText(id: id, text: "scanned words")
        XCTAssertEqual(try texts(db, "scanned"), ["legacy invoice"])
    }

    // MARK: - Older clips

    func testOlderClipsKeysetPaging() throws {
        let db = try makeTestDatabase(self)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 { try add(db, clip("c\(i)", at: base.addingTimeInterval(Double(i)))) }
        let all = try db.allClips()  // newest first: c4...c0
        let page = try db.olderClips(beforeCreatedAt: all[1].createdAt, id: all[1].id!, limit: 2)
        XCTAssertEqual(page.map(\.contentText), ["c2", "c1"])
        XCTAssertEqual(try db.olderClips(beforeCreatedAt: all[4].createdAt, id: all[4].id!, limit: 2).count, 0)
        XCTAssertEqual(try db.existingClipIDs(among: [all[0].id!, 9999]), [all[0].id!])
    }

    func testStoreLoadOlderPastResidentWindow() async throws {
        let db = try makeTestDatabase(self)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.dbQueue.write { conn in
            for i in 0..<320 {
                try conn.execute(sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                    VALUES (?, 'public.utf8-plain-text', ?, 'text')
                    """, arguments: ["clip \(i)", base.addingTimeInterval(Double(i))])
            }
        }
        // ValueObservation must be started from the main thread.
        let store = await MainActor.run {
            ClipStore(database: db, pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)))
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { store.recents.count }) == 300 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let resident = await MainActor.run { store.recents.count }
        XCTAssertEqual(resident, 300)
        let page = await store.loadOlder(limit: 100)
        XCTAssertEqual(page.count, 20)
        let more = await MainActor.run { store.hasMoreOlder }
        XCTAssertFalse(more)
        let shown = await MainActor.run { store.clips.count }
        XCTAssertEqual(shown, 320)
    }
}
