import GRDB
import XCTest
@testable import Clippy

/// The observed window decodes only rows that changed since the previous pulse,
/// and still shows every change (insert, update from any path, delete, unfile).
final class ClipWindowLoaderTests: XCTestCase {
    /// The window query before the loader: every row of the window, blobs included,
    /// decoded on every pulse. Kept here as the "before" side of the measurement.
    private static let fullWindowSQL = """
        SELECT * FROM clips
        WHERE id IN (SELECT clipID FROM clip_category)
        OR id IN (SELECT id FROM clips ORDER BY createdAt DESC, id DESC LIMIT ?)
        ORDER BY createdAt DESC, id DESC
        """

    /// `count` rich-text clips, oldest first, all filed in one category.
    @discardableResult
    private func seedFiled(_ db: ClipDatabase, count: Int, blobBytes: Int = 0) throws -> Int64 {
        let category = try db.createCategory(named: "Work", colorHex: "#154734", iconKind: .symbol, iconValue: "folder")
        let categoryID = try XCTUnwrap(category.id)
        let now = Date()
        let rtf = blobBytes > 0 ? Data(repeating: 0x7B, count: blobBytes) : nil
        let html = blobBytes > 0 ? Data(repeating: 0x3C, count: blobBytes) : nil
        try db.dbQueue.write { conn in
            for index in 0..<count {
                var clip = Clip(
                    id: nil, contentText: "filed \(index)", contentRTF: rtf, contentHTML: html,
                    typeIdentifier: "public.rtf", sourceAppBundleID: nil, sourceAppName: "Notes",
                    createdAt: now.addingTimeInterval(-Double(100_000 + count - index)))
                try clip.insert(conn)
            }
            try conn.execute(
                sql: "INSERT INTO clip_category (clipID, categoryID, addedAt, sortOrder) SELECT id, ?, ?, id FROM clips",
                arguments: [categoryID, now])
        }
        return categoryID
    }

    private func load(_ loader: ClipWindowLoader, _ db: ClipDatabase, limit: Int = 300) throws -> ClipWindow {
        try db.dbQueue.read { try loader.load($0, limit: limit, generation: db.contentGeneration) }
    }

    func testOnlyChangedRowsAreDecoded() throws {
        let db = try makeTestDatabase(self)
        try seedFiled(db, count: 50)
        var recent = makeTextClip("recent")
        try db.saveCapturedClip(&recent, cap: 1_000)
        let loader = ClipWindowLoader()

        XCTAssertEqual(try load(loader, db).clips.count, 51)
        XCTAssertEqual(loader.lastDecodedRowCount, 51, "first load decodes the whole window")
        let unchanged = try load(loader, db)
        XCTAssertEqual(unchanged.clips.count, 51)
        XCTAssertEqual(loader.lastDecodedRowCount, 0, "a pulse with no changed rows decodes nothing")

        var capture = makeTextClip("captured")
        try db.saveCapturedClip(&capture, cap: 1_000)
        let afterCapture = try load(loader, db)
        XCTAssertEqual(afterCapture.clips.first?.contentText, "captured")
        XCTAssertEqual(loader.lastDecodedRowCount, 1, "a capture decodes only the new row")
    }

    /// Seeded fault: reusing a cached row without checking its version would keep
    /// showing the old OCR text and title of a filed clip older than the window.
    func testUpdatesFromEveryPathReachTheWindow() throws {
        let db = try makeTestDatabase(self)
        try seedFiled(db, count: 20)
        let loader = ClipWindowLoader()
        let first = try load(loader, db, limit: 5)
        let oldest = try XCTUnwrap(first.clips.last?.id)

        try db.setOCRText(id: oldest, text: "recognised words")
        var window = try load(loader, db, limit: 5)
        XCTAssertEqual(window.clips.first { $0.id == oldest }?.ocrText, "recognised words")
        XCTAssertEqual(loader.lastDecodedRowCount, 1)

        try db.updateClipTitle(id: oldest, userTitle: "Renamed")
        window = try load(loader, db, limit: 5)
        XCTAssertEqual(window.clips.first { $0.id == oldest }?.userTitle, "Renamed")
        XCTAssertEqual(loader.lastDecodedRowCount, 1)

        // Another writer's raw SQL (the MCP server's path) bumps the version too.
        try db.dbQueue.write { try $0.execute(sql: "UPDATE clips SET contentText = 'external' WHERE id = ?", arguments: [oldest]) }
        window = try load(loader, db, limit: 5)
        XCTAssertEqual(window.clips.first { $0.id == oldest }?.contentText, "external")
        XCTAssertEqual(loader.lastDecodedRowCount, 1)
    }

    func testDeletedAndUnfiledRowsLeaveTheWindow() throws {
        let db = try makeTestDatabase(self)
        let categoryID = try seedFiled(db, count: 10)
        let loader = ClipWindowLoader()
        let ids = try load(loader, db, limit: 2).clips.compactMap(\.id)
        XCTAssertEqual(ids.count, 10)

        try db.deleteClip(id: ids[0])
        XCTAssertFalse(try load(loader, db, limit: 2).clips.contains { $0.id == ids[0] })
        XCTAssertEqual(loader.lastDecodedRowCount, 0)

        // The oldest filed clip falls outside the 2-clip recents window once unfiled.
        try db.setClip(ids[9], inCategory: categoryID, false)
        XCTAssertFalse(try load(loader, db, limit: 2).clips.contains { $0.id == ids[9] })
    }

    func testTriggerBumpsTheVersionOnEachUpdate() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("versioned")
        try db.saveCapturedClip(&clip, cap: 100)
        let id = try XCTUnwrap(clip.id)
        func version() throws -> Int64 {
            try db.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT COALESCE((SELECT version FROM clip_version WHERE clipID = ?), 0)", arguments: [id]) ?? -1 }
        }
        XCTAssertEqual(try version(), 0)
        try db.updateClipTitle(id: id, userTitle: "One")
        XCTAssertEqual(try version(), 1)
        try db.setOCRText(id: id, text: "two")
        XCTAssertEqual(try version(), 2)

        try db.deleteClip(id: id)
        let leftover = try db.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clip_version WHERE clipID = ?", arguments: [id])
        }
        XCTAssertEqual(leftover, 0, "deleting a clip drops its version row")
    }

    /// Edits of every kind must leave the full-text index consistent. Seeded fault:
    /// the old self-updating row-version trigger, which fails here with SQLite error 11
    /// (database disk image is malformed) because its nested UPDATE re-ran the FTS sync
    /// triggers in an undefined order.
    func testEditsKeepTheSearchIndexIntact() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("alpha words")
        try db.saveCapturedClip(&clip, cap: 100)
        let id = try XCTUnwrap(clip.id)

        XCTAssertNoThrow(try db.updateClipTitle(id: id, userTitle: "Renamed title"))
        XCTAssertNoThrow(try db.setOCRText(id: id, text: "beta words"))
        XCTAssertNoThrow(try db.dbQueue.write {
            try $0.execute(sql: "UPDATE clips SET contentText = 'gamma words' WHERE id = ?", arguments: [id])
        })

        try db.dbQueue.write { conn in
            XCTAssertEqual(try String.fetchOne(conn, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertNoThrow(try conn.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('integrity-check')"))
        }
    }

    /// A backup restore reuses ids and versions from another file, so the cache must
    /// start over: the restored contents are what the window shows. Seeded fault:
    /// the edited row and the restored row carry the same (id, version), as rows of a
    /// backup made before row versions existed do (no clip_version entry reads as 0), so
    /// only the generation tells them apart.
    func testRestoreDropsTheCache() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("before backup")
        try db.saveCapturedClip(&clip, cap: 100)
        let id = try XCTUnwrap(clip.id)
        let snapshot = try db.createBackup()
        try db.updateClipTitle(id: id, userTitle: "edited after backup")
        try db.dbQueue.write { try $0.execute(sql: "DELETE FROM clip_version WHERE clipID = ?", arguments: [id]) }

        let loader = ClipWindowLoader()
        XCTAssertEqual(try load(loader, db).clips.first { $0.id == id }?.userTitle, "edited after backup")
        try db.restoreBackup(snapshot)
        XCTAssertNil(try load(loader, db).clips.first { $0.id == id }?.userTitle,
                     "the restored row, not the cached edit")
    }

    /// End to end through the store's ValueObservation: an OCR result on a filed
    /// clip older than the window reaches its category pane.
    @MainActor
    func testStoreShowsAnEditToAnOldFiledClip() throws {
        let db = try makeTestDatabase(self)
        let categoryID = try seedFiled(db, count: 5)
        for index in 0..<310 {
            var recent = makeTextClip("recent \(index)")
            try db.saveCapturedClip(&recent, cap: 10_000)
        }
        let store = ClipStore(database: db)
        let loaded = expectation(description: "window")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if store.clipsForCategory(categoryID).count == 5 { loaded.fulfill() }
        }
        wait(for: [loaded], timeout: 5)
        timer.invalidate()
        let oldest = try XCTUnwrap(store.clipsForCategory(categoryID).last?.id)

        try db.setOCRText(id: oldest, text: "late ocr")
        let updated = expectation(description: "edit observed")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if store.clipsForCategory(categoryID).first(where: { $0.id == oldest })?.ocrText == "late ocr" { updated.fulfill() }
        }
        wait(for: [updated], timeout: 5)
        poll.invalidate()
    }

    /// Before and after: one edit with 3,000 filed rich-text clips. The full reload
    /// decodes every row of the window; the loader decodes the one that changed.
    func testOneEditCostsOneRowNotTheWholeWindow() throws {
        let db = try makeTestDatabase(self)
        try seedFiled(db, count: 3_000, blobBytes: 6_000)
        let loader = ClipWindowLoader()
        _ = try load(loader, db)
        let ids = try db.dbQueue.read { try Int64.fetchAll($0, sql: "SELECT id FROM clips ORDER BY id LIMIT 5") }

        let clock = ContinuousClock()
        func millis(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var full = Double.infinity, incremental = Double.infinity
        var fullRows = 0
        for (round, id) in ids.enumerated() {
            try db.updateClipTitle(id: id, userTitle: "edit \(round)")
            full = min(full, millis(try clock.measure {
                fullRows = try db.dbQueue.read { try Clip.fetchAll($0, sql: Self.fullWindowSQL, arguments: [300]).count }
            }))
            incremental = min(incremental, millis(try clock.measure { _ = try load(loader, db) }))
            XCTAssertEqual(loader.lastDecodedRowCount, 1)
        }
        print(String(format: "PERF window pulse after one edit, 3000 filed rich clips: full reload %.2f ms (%d rows decoded) -> incremental %.2f ms (%d row decoded) (best of 5)",
                     full, fullRows, incremental, loader.lastDecodedRowCount))
        XCTAssertEqual(fullRows, 3_000)
        XCTAssertLessThan(incremental, full, "decoding one row must beat decoding the whole window")
    }

    /// Splits the cost of a from-scratch window load into its steps (best of 5), same
    /// seed as the pulse benchmark. The "full reload" there is the pre-loader
    /// `SELECT *` with blobs; this times what a fresh loader actually does.
    func testWindowFullReloadSplit() throws {
        let db = try makeTestDatabase(self)
        try seedFiled(db, count: 3_000, blobBytes: 6_000)
        for index in 0..<300 {
            var recent = makeTextClip("recent \(index)")
            try db.saveCapturedClip(&recent, cap: 10_000)
        }
        let clock = ContinuousClock()
        func millis(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        func best(_ body: () throws -> Void) rethrows -> Double {
            var result = Double.infinity
            for _ in 0..<5 { result = min(result, millis(try clock.measure(body))) }
            return result
        }
        let ids = try db.dbQueue.read { try Int64.fetchAll($0, sql: "SELECT id FROM clips ORDER BY id") }
        let chunks = stride(from: 0, to: ids.count, by: ClipWindowLoader.chunkSize).map {
            Array(ids[$0..<min($0 + ClipWindowLoader.chunkSize, ids.count)])
        }
        var decoded = 0
        let stamps = try best {
            _ = try db.dbQueue.read { try Row.fetchAll($0, sql: ClipWindowLoader.stampsSQL, arguments: [300]).count }
        }
        let fetchOnly = try best {
            try db.dbQueue.read { conn in
                for chunk in chunks {
                    _ = try Row.fetchAll(conn, sql: ClipWindowLoader.freshSQL(count: chunk.count), arguments: StatementArguments(chunk)).count
                }
            }
        }
        let fetchDecode = try best {
            try db.dbQueue.read { conn in
                for chunk in chunks {
                    let rows = try Row.fetchAll(conn, sql: ClipWindowLoader.freshSQL(count: chunk.count), arguments: StatementArguments(chunk))
                    decoded = 0
                    for row in rows { _ = try Clip.light(row); decoded += 1 }
                }
            }
        }
        let cursorDecode = try best {
            try db.dbQueue.read { conn in
                for chunk in chunks {
                    let cursor = try Row.fetchCursor(conn, sql: ClipWindowLoader.freshSQL(count: chunk.count), arguments: StatementArguments(chunk))
                    while let row = try cursor.next() { _ = try Clip.light(row) }
                }
            }
        }
        var loaded = 0
        let whole = try best {
            loaded = try load(ClipWindowLoader(), db).clips.count
        }
        print(String(format: "PERF reload split stamps query: %.2f ms", stamps))
        print(String(format: "PERF reload split fresh-row fetchAll, no decode: %.2f ms", fetchOnly))
        print(String(format: "PERF reload split fresh-row fetchAll + Clip.light: %.2f ms (%d rows)", fetchDecode, decoded))
        print(String(format: "PERF reload split fresh-row cursor + Clip.light: %.2f ms", cursorDecode))
        print(String(format: "PERF reload split whole loader.load on a fresh loader: %.2f ms (%d clips)", whole, loaded))
        XCTAssertEqual(loaded, 3_300)
    }
}
