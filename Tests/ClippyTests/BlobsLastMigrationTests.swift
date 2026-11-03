import GRDB
import XCTest
@testable import Clippy

/// v14-blobs-last rebuilds `clips` with contentRTF and contentHTML declared last. The rebuild
/// must keep every row, id, index, trigger, foreign key and full-text entry.
final class BlobsLastMigrationTests: XCTestCase {
    private static let expectedColumns = [
        "id", "contentText", "typeIdentifier", "sourceAppBundleID", "sourceAppName", "createdAt",
        "contentKind", "mediaFilename", "thumbFilename", "pixelWidth", "pixelHeight", "byteSize",
        "userTitle", "filePath", "ocrText", "unfiledAt", "contentRTF", "contentHTML",
    ]

    private func columnNames(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { try $0.columns(in: "clips").map(\.name) }
    }

    private func rowsByID(_ queue: DatabaseQueue) throws -> [Int64: [String: DatabaseValue]] {
        try queue.read { db in
            var result: [Int64: [String: DatabaseValue]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM clips") {
                let id: Int64 = row["id"]
                result[id] = Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
            }
            return result
        }
    }

    private func schemaObjects(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT type, name, sql FROM sqlite_master
                WHERE type IN ('index', 'trigger') ORDER BY name
                """).map { row in
                let type: String = row["type"]
                let name: String = row["name"]
                let sql: String? = row["sql"]
                return "\(type)|\(name)|\(sql ?? "")"
            }
        }
    }

    private func match(_ queue: DatabaseQueue, _ term: String) throws -> [Int64] {
        let args: StatementArguments = [term]
        return try queue.read {
            try Int64.fetchAll($0, sql: "SELECT rowid FROM clips_fts WHERE clips_fts MATCH ? ORDER BY rowid", arguments: args)
        }
    }

    /// Seeds a v13 database; returns the ids (rich, plain, image, titled, doomed).
    private func seedV13(_ queue: DatabaseQueue) throws -> [Int64] {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                VALUES ('Work', '#FF0000', 'symbol', 'folder', 1, 0, '2026-01-01 00:00:00.000')
                """)
            let rtf = Data(repeating: 0x7B, count: 9_000)
            let html = Data(repeating: 0x3C, count: 9_000)
            let insert = """
                INSERT INTO clips (contentText, contentRTF, contentHTML, typeIdentifier, sourceAppBundleID,
                                   sourceAppName, createdAt, contentKind, mediaFilename, thumbFilename,
                                   pixelWidth, pixelHeight, byteSize, userTitle, filePath, ocrText)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            let rich: StatementArguments = [
                "rich quarterly report", rtf, html, "public.rtf", "com.apple.Notes", "Notes",
                "2026-02-01 10:00:00.000", "text", nil, nil, nil, nil, 21, nil, nil, nil,
            ]
            let plain: StatementArguments = [
                "plain budget words", nil, nil, "public.utf8-plain-text", nil, nil,
                "2026-02-02 10:00:00.000", "text", nil, nil, nil, nil, 18, nil, nil, nil,
            ]
            let image: StatementArguments = [
                "", nil, nil, "public.png", "com.apple.Preview", "Preview",
                "2026-02-03 10:00:00.000", "image", "m1.png", "t1.png", 640, 480, 4096, nil, nil, "scanned invoice",
            ]
            let titled: StatementArguments = [
                "titled body", rtf, nil, "public.rtf", nil, nil,
                "2026-02-04 10:00:00.000", "file", nil, nil, nil, nil, 11, "Zebra title", "/tmp/a.txt", nil,
            ]
            let doomed: StatementArguments = [
                "doomed last clip", nil, nil, "public.utf8-plain-text", nil, nil,
                "2026-02-05 10:00:00.000", "text", nil, nil, nil, nil, 16, nil, nil, nil,
            ]
            for args in [rich, plain, image, titled, doomed] { try db.execute(sql: insert, arguments: args) }
            try db.execute(sql: """
                INSERT INTO clip_category (clipID, categoryID, addedAt, sortOrder)
                VALUES (1, 1, '2026-02-06 00:00:00.000', 0), (3, 1, '2026-02-06 00:00:00.000', 1),
                       (5, 1, '2026-02-06 00:00:00.000', 2)
                """)
            // Bumps clip_version for id 2; deleting id 5 leaves the AUTOINCREMENT mark at 5.
            try db.execute(sql: "UPDATE clips SET sourceAppName = 'Edited' WHERE id = 2")
            try db.execute(sql: "DELETE FROM clips WHERE id = 5")
        }
        return [1, 2, 3, 4, 5]
    }

    func testBlobsLastMigrationKeepsEveryRow() throws {
        let queue = try DatabaseQueue()
        let migrator = ClipDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "v13-row-version")
        _ = try seedV13(queue)

        let beforeColumns = try columnNames(queue)
        XCTAssertEqual(Array(beforeColumns.prefix(4)), ["id", "contentText", "contentRTF", "contentHTML"])
        let beforeRows = try rowsByID(queue)
        let beforeObjects = try schemaObjects(queue)
        let beforeLinks = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM clip_category ORDER BY clipID, categoryID") }
            .map { "\($0)" }
        let beforeVersions = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM clip_version ORDER BY clipID") }
            .map { "\($0)" }
        XCTAssertEqual(beforeRows.count, 4)

        try migrator.migrate(queue)

        let afterColumns = try columnNames(queue)
        XCTAssertEqual(afterColumns, Self.expectedColumns)
        XCTAssertEqual(Array(afterColumns.suffix(2)), ["contentRTF", "contentHTML"])
        XCTAssertEqual(try rowsByID(queue), beforeRows, "every row equal by id across all columns")
        XCTAssertEqual(try schemaObjects(queue), beforeObjects, "indexes and triggers byte-identical")
        XCTAssertEqual(try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM clip_category ORDER BY clipID, categoryID") }
            .map { "\($0)" }, beforeLinks)
        XCTAssertEqual(try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM clip_version ORDER BY clipID") }
            .map { "\($0)" }, beforeVersions)
        try queue.read { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
        }

        // Full-text index still points at the same rowids.
        try queue.write { try $0.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('integrity-check')") }
        XCTAssertEqual(try match(queue, "quarterly"), [1])
        XCTAssertEqual(try match(queue, "budget"), [2])
        XCTAssertEqual(try match(queue, "invoice"), [3])
        XCTAssertEqual(try match(queue, "zebra"), [4])
        XCTAssertEqual(try match(queue, "doomed"), [], "the deleted clip left no FTS entry")

        // Ids of deleted clips are not reused: the AUTOINCREMENT high-water mark survived.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO clips (contentText, typeIdentifier, createdAt)
                VALUES ('after migration', 'public.utf8-plain-text', '2026-03-01 00:00:00.000')
                """)
            XCTAssertEqual(db.lastInsertedRowID, 6)
        }
        XCTAssertEqual(try match(queue, "migration"), [6])
    }

    func testBlobsLastMigrationKeepsTriggersAndCascadesWorking() throws {
        let queue = try DatabaseQueue()
        let migrator = ClipDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "v13-row-version")
        _ = try seedV13(queue)
        try migrator.migrate(queue)

        // Editing a clip bumps clip_version and re-indexes it.
        let before = try queue.read { try Int.fetchOne($0, sql: "SELECT version FROM clip_version WHERE clipID = 4") }
        try queue.write { try $0.execute(sql: "UPDATE clips SET contentText = 'renamed giraffe' WHERE id = 4") }
        let after = try queue.read { try Int.fetchOne($0, sql: "SELECT version FROM clip_version WHERE clipID = 4") }
        XCTAssertEqual(after, (before ?? 0) + 1)
        XCTAssertEqual(try match(queue, "giraffe"), [4])

        // Removing a clip from a category stamps unfiledAt (trigger on clip_category).
        try queue.write { try $0.execute(sql: "DELETE FROM clip_category WHERE clipID = 3") }
        XCTAssertNotNil(try queue.read { try String.fetchOne($0, sql: "SELECT unfiledAt FROM clips WHERE id = 3") })

        // Deleting a clip cascades its category rows, version row and FTS entry.
        try queue.write { try $0.execute(sql: "DELETE FROM clips WHERE id = 1") }
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_category WHERE clipID = 1"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_version WHERE clipID = 1"), 0)
        }
        XCTAssertEqual(try match(queue, "quarterly"), [])
        try queue.write { try $0.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('integrity-check')") }
    }

    func testFreshInstallEndsWithBlobsLastColumnOrder() throws {
        let queue = try DatabaseQueue()
        try ClipDatabase.makeMigrator().migrate(queue)
        XCTAssertEqual(try columnNames(queue), Self.expectedColumns)
        try queue.read { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        let db = try makeTestDatabase(self)
        XCTAssertEqual(try db.dbQueue.read { try $0.columns(in: "clips").map(\.name) }, Self.expectedColumns)
    }
}
