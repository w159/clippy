import XCTest
import GRDB
@testable import Clippy

/// The MCP server writes to Clippy's SQLite file from another process. GRDB's
/// ValueObservation cannot see that, so a clip added over MCP used to stay
/// invisible in the panel until the next in-app write or an app restart.
/// `data_version` is the signal that closes the gap.
final class ExternalChangeWatcherTests: XCTestCase {
    /// No file-store reloaders: these tests must not touch the user's real
    /// scripts.json / ai-actions.json through the shared singletons.
    private func makeWatcher(_ database: ClipDatabase) -> ExternalChangeWatcher {
        ExternalChangeWatcher(database: database, fileStoreReloaders: [])
    }

    func testOurOwnWritesDoNotLookExternal() throws {
        let database = try makeTestDatabase(self)
        let watcher = makeWatcher(database)
        watcher.start()

        try database.insertTextClip("written by the app itself")

        XCTAssertFalse(
            watcher.tick(),
            "data_version is unchanged for commits on the same connection, so an in-app capture must not trigger a refresh"
        )
    }

    func testAnotherConnectionsWriteIsDetectedOnce() throws {
        let database = try makeTestDatabase(self)
        let watcher = makeWatcher(database)
        watcher.start()

        // A second DatabaseQueue on the same file stands in for the MCP server
        // process: a separate connection committing behind GRDB's back.
        let otherProcess = try DatabaseQueue(path: database.databaseURL.path)
        try otherProcess.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips (contentText, typeIdentifier, sourceAppName, createdAt, contentKind)
                    VALUES ('added by another process', 'public.utf8-plain-text', 'clippy-mcp', ?, 'text')
                    """,
                arguments: ["2026-09-16 12:00:00.000"]
            )
        }

        XCTAssertTrue(watcher.tick(), "an external commit must trigger a refresh")
        XCTAssertFalse(watcher.tick(), "and must not keep firing once it has been observed")
    }

    func testNotifyExternalChangesSucceeds() throws {
        let database = try makeTestDatabase(self)
        XCTAssertNoThrow(try database.notifyExternalChanges())
    }
}
