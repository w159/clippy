import GRDB
import XCTest
@testable import Clippy

/// DAT-06/08/11/13/15, SBR-03/04/07: migrations against an old-schema copy,
/// category uniqueness, ceiling eviction, backup/restore, orphan reporting.
final class DataLayerDatabaseTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: StorageCeiling.defaultsKey)
        super.tearDown()
    }

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Migrations on an old-schema DB

    /// Builds a v6 database (before the unique-name index and the sortOrder
    /// repair) holding duplicate category names and legacy negative sortOrders.
    private struct OldDatabase {
        let url: URL
        let media: URL
        let legacyCat: Int64
        let reorderedCat: Int64
    }

    private func makeV6Database() throws -> OldDatabase {
        let dir = try tempDir("v6")
        let url = dir.appendingPathComponent("old.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(queue, upTo: "v6-file-clips")
        var ids: [Int64] = []
        try queue.write { db in
            for name in ["Work", "work", "WORK", "Legacy", "Reordered"] {
                try db.execute(
                    sql: """
                        INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                        VALUES (?, '#000000', 'symbol', 'tag', 5, 0, ?)
                        """,
                    arguments: [name, Date(timeIntervalSince1970: Double(ids.count))]
                )
                ids.append(db.lastInsertedRowID)
            }
            for index in 0..<3 {
                try db.execute(
                    sql: """
                        INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                        VALUES (?, 'public.utf8-plain-text', ?, 'text')
                        """,
                    arguments: ["clip\(index)", Date()]
                )
                let clipID = db.lastInsertedRowID
                // Legacy category: v5's bad backfill left 0, -1, -2 (oldest listed first).
                try db.execute(
                    sql: "INSERT INTO clip_category (clipID, categoryID, addedAt, sortOrder) VALUES (?, ?, ?, ?)",
                    arguments: [clipID, ids[3], Date(timeIntervalSince1970: 1000 + Double(index)), -index]
                )
                // Reordered category: the user's gap-free custom order, deliberately not by date.
                try db.execute(
                    sql: "INSERT INTO clip_category (clipID, categoryID, addedAt, sortOrder) VALUES (?, ?, ?, ?)",
                    arguments: [clipID, ids[4], Date(timeIntervalSince1970: 1000 + Double(index)), index]
                )
            }
        }
        return OldDatabase(url: url, media: dir.appendingPathComponent("media"), legacyCat: ids[3], reorderedCat: ids[4])
    }

    func testMigrationsRepairAnOldSchemaCopyWithoutLosingData() throws {
        let old = try makeV6Database()
        let db = try ClipDatabase(databaseURL: old.url, mediaDirectory: old.media)

        // SBR-04: duplicates were renamed, not dropped, and the index now exists.
        let names = try db.categories().map(\.name).sorted()
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count, "names are unique ignoring case")
        XCTAssertTrue(names.contains("Work"))
        XCTAssertTrue(names.contains("work 2") || names.contains("work"), "duplicates kept under new names")
        XCTAssertEqual(names.count, 6, "Pinned starter + 5 seeded categories all survive")

        // SBR-07: legacy category renumbered 0... by addedAt DESC (newest first).
        let legacy = try db.clipsForCategory(old.legacyCat).map(\.contentText)
        XCTAssertEqual(legacy, ["clip2", "clip1", "clip0"])
        let legacyOrders: [Int] = try db.dbQueue.read {
            try Int.fetchAll($0, sql: "SELECT sortOrder FROM clip_category WHERE categoryID = ? ORDER BY sortOrder",
                             arguments: [old.legacyCat])
        }
        XCTAssertEqual(legacyOrders, [0, 1, 2])

        // A category the user already reordered (all >= 0) must NOT be re-sorted.
        let reordered = try db.clipsForCategory(old.reorderedCat).map(\.contentText)
        XCTAssertEqual(reordered, ["clip0", "clip1", "clip2"], "custom order preserved")
    }

    func testCategoryNameUniqueIndexRejectsCaseVariantsAtTheSchemaLevel() throws {
        let db = try makeTestDatabase(self)
        _ = try db.createCategory(named: "Alpha", colorHex: "#111111", iconKind: .symbol, iconValue: "a")
        XCTAssertThrowsError(try db.dbQueue.write { grdb in
            try grdb.execute(
                sql: """
                    INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                    VALUES ('ALPHA', '#000', 'symbol', 'x', 9, 0, ?)
                    """, arguments: [Date()])
        }, "the NOCASE unique index must reject a case variant even when the app-level check is bypassed")
    }

    func testCreateAndRenameCategoryRejectDuplicatesAndEmptyNames() throws {
        let db = try makeTestDatabase(self)
        _ = try db.createCategory(named: "Alpha", colorHex: "#111111", iconKind: .symbol, iconValue: "a")
        let beta = try db.createCategory(named: "Beta", colorHex: "#222222", iconKind: .symbol, iconValue: "b")

        XCTAssertThrowsError(try db.createCategory(named: "  alpha ", colorHex: "#1", iconKind: .symbol, iconValue: "a")) {
            XCTAssertEqual($0 as? CategoryError, .duplicateName("alpha"))
        }
        XCTAssertThrowsError(try db.createCategory(named: "   ", colorHex: "#1", iconKind: .symbol, iconValue: "a")) {
            XCTAssertEqual($0 as? CategoryError, .emptyName)
        }
        var renamed = beta
        renamed.name = "ALPHA"
        XCTAssertThrowsError(try db.updateCategory(renamed)) {
            XCTAssertEqual($0 as? CategoryError, .duplicateName("ALPHA"))
        }
        renamed.name = "BETA"  // only a case change of itself: allowed
        XCTAssertNoThrow(try db.updateCategory(renamed))
        XCTAssertEqual(try db.categoryNames().filter { $0.lowercased() == "beta" }.count, 1)
    }

    // MARK: - Ceiling (DAT-06/11)

    private func bulkInsert(_ db: ClipDatabase, count: Int) throws {
        try db.dbQueue.write { grdb in
            for index in 0..<count {
                try grdb.execute(
                    sql: """
                        INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                        VALUES (?, 'public.utf8-plain-text', ?, 'text')
                        """,
                    arguments: ["bulk\(index)", Date(timeIntervalSince1970: 1_000 + Double(index))]
                )
            }
        }
    }

    func testCeilingEvictsOldestButNeverPinnedOrCategorizedClips() throws {
        StorageCeiling.current = 100
        let db = try makeTestDatabase(self)
        try bulkInsert(db, count: 100)
        let category = try db.createCategory(named: "Keep", colorHex: "#1", iconKind: .symbol, iconValue: "k")
        let oldest = try db.allClips().suffix(3)  // the three OLDEST rows
        for clip in oldest { try db.setClip(try XCTUnwrap(clip.id), inCategory: try XCTUnwrap(category.id), true) }

        // Every insert path goes through the chokepoint; cap 0 disables the history cap.
        try db.insertTextClip("fresh one", cap: 0)
        try db.insertTextClip("fresh two", cap: 0)

        XCTAssertEqual(try db.storageUsage().count, 100, "trimmed back to the ceiling")
        let texts = Set(try db.allClips().map(\.contentText))
        for clip in oldest { XCTAssertTrue(texts.contains(clip.contentText), "categorized clip survived") }
        XCTAssertTrue(texts.contains("fresh two"))
        XCTAssertFalse(texts.contains("bulk3"), "an old UNcategorized clip was evicted instead")
    }

    func testCeilingLeavesCategorizedClipsEvenWhenTheyAloneExceedIt() throws {
        StorageCeiling.current = 100
        let db = try makeTestDatabase(self)
        try bulkInsert(db, count: 105)
        let category = try db.createCategory(named: "All", colorHex: "#1", iconKind: .symbol, iconValue: "k")
        for clip in try db.allClips() { try db.setClip(try XCTUnwrap(clip.id), inCategory: try XCTUnwrap(category.id), true) }
        try db.insertTextClip("uncategorized", cap: 0)
        XCTAssertEqual(try db.storageUsage().count, 105, "only the uncategorized newcomer could go, and it did")
        XCTAssertFalse(try db.allClips().contains { $0.contentText == "uncategorized" })
    }

    func testCeilingAccessorClampsAndWarningThresholdIsNinetyPercent() {
        StorageCeiling.current = 5
        XCTAssertEqual(StorageCeiling.current, StorageCeiling.minimum)
        XCTAssertFalse(StorageUsage(count: 899, ceiling: 1000).isNearCeiling)
        XCTAssertTrue(StorageUsage(count: 900, ceiling: 1000).isNearCeiling)
    }

    // MARK: - Import transaction (DAT-08)

    func testFailedImportRollsBackEverything() throws {
        let db = try makeTestDatabase(self)
        try db.dbQueue.write { grdb in
            try grdb.execute(sql: """
                CREATE TRIGGER boom BEFORE INSERT ON clips WHEN NEW.contentText = 'boom'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        let toml = """
            schema_version = 1
            exported_at = "2026-01-01T00:00:00Z"

            [[category]]
            name = "Imported"
            color = "#FF0000"
            icon_kind = "symbol"
            icon = "tag"
            position = 3
            starter = false

              [[category.clip]]
              kind = "text"
              text = "first ok"

              [[category.clip]]
              kind = "text"
              text = "boom"
            """
        XCTAssertThrowsError(try ClippyArchive.importTOML(toml, into: db))
        XCTAssertFalse(try db.allClips().contains { $0.contentText == "first ok" }, "no partial import")
        XCTAssertFalse(try db.categories().contains { $0.name == "Imported" }, "category rolled back too")
    }

    // MARK: - Pool / WAL (DAT-13)

    func testDatabaseRunsInWALModeWithBusyTimeout() throws {
        let db = try makeTestDatabase(self)
        XCTAssertTrue(db.dbQueue is DatabasePool)
        let mode = try db.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode?.lowercased(), "wal")
    }

    // MARK: - Backups, integrity, vacuum, orphans (DAT-15)

    func testBackupThenRestoreBringsDeletedClipsBack() throws {
        let db = try makeTestDatabase(self)
        try db.insertTextClip("precious", cap: 0)
        let snapshot = try db.createBackup()
        XCTAssertEqual(db.listBackups().map(\.id), [snapshot.id])

        let id = try XCTUnwrap(db.allClips().first?.id)
        try db.deleteClip(id: id)
        XCTAssertTrue(try db.allClips().isEmpty)

        try db.restoreBackup(snapshot)
        XCTAssertEqual(try db.allClips().map(\.contentText), ["precious"])
        XCTAssertGreaterThanOrEqual(db.listBackups().count, 2, "restore took a safety snapshot first")
        XCTAssertTrue(try db.integrityCheck().isHealthy)
    }

    func testRestoreRefusesACorruptSnapshotAndLeavesLiveDataAlone() throws {
        let db = try makeTestDatabase(self)
        try db.insertTextClip("live data", cap: 0)
        let snapshot = try db.createBackup()
        try Data("this is not a database".utf8).write(to: snapshot.databaseURL)

        XCTAssertThrowsError(try db.restoreBackup(snapshot))
        XCTAssertEqual(try db.allClips().map(\.contentText), ["live data"])
        XCTAssertEqual(db.listBackups().count, 1, "no safety snapshot is taken for a refused restore")
    }

    func testRestoreOfMissingSnapshotThrows() throws {
        let db = try makeTestDatabase(self)
        let snapshot = try db.createBackup()
        try db.deleteBackup(snapshot)
        XCTAssertThrowsError(try db.restoreBackup(snapshot)) {
            XCTAssertEqual($0 as? BackupError, .snapshotMissing)
        }
    }

    func testIntegrityCheckAndVacuumOnHealthyDatabase() throws {
        let db = try makeTestDatabase(self)
        try bulkInsert(db, count: 50)
        XCTAssertTrue(try db.integrityCheck().isHealthy)
        try db.deleteUnclassifiedClips()
        let report = try db.vacuum()
        XCTAssertLessThanOrEqual(report.bytesAfter, report.bytesBefore + 4096)
    }

    func testOrphanMediaReportListsRemovesAndFlagsMissingFiles() throws {
        let db = try makeTestDatabase(self)
        let orphan = db.media.url(for: "orphan.bin")
        try Data("x".utf8).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: orphan.path)
        let fresh = db.media.url(for: "fresh.bin")  // younger than a minute: spared
        try Data("y".utf8).write(to: fresh)
        // A clip whose media file is gone.
        var clip = makeImageClip(.init(mediaFilename: "ghost.png", thumbFilename: "ghost-thumb.jpg",
                                       pixelWidth: 1, pixelHeight: 1, byteSize: 1))
        try db.saveCapturedImageClip(&clip, cap: 100)

        let report = try db.orphanMediaReport()
        XCTAssertEqual(report.orphanedFiles, ["orphan.bin"])
        XCTAssertEqual(report.orphanedBytes, 1)
        XCTAssertEqual(report.missingFiles, ["ghost-thumb.jpg", "ghost.png"])
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "report-only pass deletes nothing")

        XCTAssertEqual(try db.orphanMediaReport(remove: true).removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
