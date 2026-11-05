import GRDB
import XCTest
@testable import Clippy

/// 2.3.1: the default theme follows the system appearance, and an existing database with pending
/// migrations is backed up before they run.
@MainActor
final class UpgradeSafetyTests: XCTestCase {
    func testRegisteredThemeDefaultIsAutomatic() throws {
        let name = "clippy-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AppSettings.registerDefaults(defaults)
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.themePreset), ThemePreset.automatic.rawValue)
        XCTAssertNotNil(ThemePreset(rawValue: ThemePreset.automatic.rawValue), "Automatic stays selectable")
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testPreV12DatabaseIsBackedUpThenMigratedWithRowsAndBlobsIntact() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("clippy.sqlite")
        let rtf = Data((0..<9_000).map { UInt8($0 % 251) })
        let html = Data((0..<9_000).map { UInt8(($0 * 7) % 253) })
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ClipDatabase.makeMigrator().migrate(queue, upTo: "v11-perf-indexes")
            try queue.write { db in
                let insert = """
                    INSERT INTO clips (contentText, contentRTF, contentHTML, typeIdentifier, createdAt)
                    VALUES (?, ?, ?, 'public.rtf', '2026-02-01 10:00:00.000')
                    """
                try db.execute(sql: insert, arguments: ["rich one", rtf, html])
                try db.execute(sql: insert, arguments: ["rich two", rtf, nil])
                try db.execute(sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt)
                    VALUES ('plain', 'public.utf8-plain-text', '2026-02-02 10:00:00.000')
                    """)
            }
            try queue.close()
        }

        let db = try ClipDatabase(databaseURL: url, mediaDirectory: dir.appendingPathComponent("media", isDirectory: true))

        let backups = db.listBackups()
        XCTAssertEqual(backups.count, 1, "one snapshot taken before the upgrade")
        let snapshot = try XCTUnwrap(backups.first)
        let backupCount = try DatabaseQueue(path: snapshot.databaseURL.path).read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clips")
        }
        XCTAssertEqual(backupCount, 3)

        try db.dbQueue.read { conn in
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM clips"), 3)
            XCTAssertEqual(try Data.fetchOne(conn, sql: "SELECT contentRTF FROM clips WHERE contentText = 'rich one'"), rtf)
            XCTAssertEqual(try Data.fetchOne(conn, sql: "SELECT contentHTML FROM clips WHERE contentText = 'rich one'"), html)
            XCTAssertEqual(try Data.fetchOne(conn, sql: "SELECT contentRTF FROM clips WHERE contentText = 'rich two'"), rtf)
            XCTAssertNil(try Data.fetchOne(conn, sql: "SELECT contentHTML FROM clips WHERE contentText = 'rich two'"))
            let columns = try conn.columns(in: "clips").map(\.name)
            XCTAssertEqual(Array(columns.suffix(2)), ["contentRTF", "contentHTML"])
        }
    }

    func testFreshAndUpToDateDatabasesAreNotBackedUp() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("clippy.sqlite")
        let media = dir.appendingPathComponent("media", isDirectory: true)
        let fresh = try ClipDatabase(databaseURL: url, mediaDirectory: media)
        XCTAssertTrue(fresh.listBackups().isEmpty, "a new database has nothing to protect")
        let reopened = try ClipDatabase(databaseURL: url, mediaDirectory: media)
        XCTAssertTrue(reopened.listBackups().isEmpty, "no pending migrations, no snapshot")
    }
}
