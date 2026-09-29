import XCTest
import GRDB
@testable import Clippy

@MainActor
final class ClipTitleTests: XCTestCase {

    // MARK: - Schema migration

    func testV4MigrationAddsUserTitleColumn() throws {
        let db = try makeTestDatabase(self)
        // Column must exist and be nullable.
        try db.dbQueue.read { grdb in
            let info = try grdb.columns(in: "clips")
            let col = try XCTUnwrap(info.first(where: { $0.name == "userTitle" }))
            XCTAssertFalse(col.isNotNull, "userTitle must be nullable")
        }
    }

    func testV4MigrationUpgradePathFromV3() throws {
        // Build a database stopped at v3, then let the full migrator finish.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-v4-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v3.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(queue, upTo: "v3-image-clips")
        // Insert a row without userTitle (pre-v4 state).
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                    VALUES ('existing', 'public.utf8-plain-text', ?, 'text')
                    """,
                arguments: [Date()]
            )
        }

        // Run v4.
        let upgraded = try ClipDatabase(databaseURL: url)
        let clips = try upgraded.allClips()
        XCTAssertEqual(clips.count, 1, "existing rows survive the migration")
        XCTAssertNil(clips[0].userTitle, "pre-existing rows have nil userTitle after migration")
    }

    func testV4MigrationFTSPreservesExistingRowsAndUserTitle() throws {
        // Build a v3 database with a row carrying distinctive content text,
        // migrate to v4 (which drops and rebuilds clips_fts), then confirm:
        // 1. The pre-existing row is FTS-searchable by its content text.
        // 2. Setting a userTitle afterwards makes it findable by that title too.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-v4-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v3fts.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(queue, upTo: "v3-image-clips")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                    VALUES ('xyzzyDistinctive', 'public.utf8-plain-text', ?, 'text')
                    """,
                arguments: [Date()]
            )
        }

        // Run v4 migration (drops and rebuilds clips_fts).
        let upgraded = try ClipDatabase(databaseURL: url)

        // 1. Pre-existing row is findable by its content text.
        let byContent = try upgraded.searchClips(matching: "xyzzyDistinctive", limit: 10)
        XCTAssertEqual(byContent.count, 1, "FTS must find the pre-existing row by content text after v4 migration")

        // 2. After setting a userTitle the row is also findable by that title.
        let clipID = try XCTUnwrap(upgraded.allClips().first?.id)
        try upgraded.updateClipTitle(id: clipID, userTitle: "PostMigrationTitle")
        let byTitle = try upgraded.searchClips(matching: "PostMigrationTitle", limit: 10)
        XCTAssertEqual(byTitle.count, 1, "FTS must find the pre-existing row by its newly-set userTitle")
        XCTAssertEqual(byTitle[0].id, clipID)
    }

    // MARK: - Title persistence round-trip

    func testUpdateClipTitlePersistsAndReloads() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("hello")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        try db.updateClipTitle(id: clipID, userTitle: "My Snippet")

        let loaded = try XCTUnwrap(db.allClips().first)
        XCTAssertEqual(loaded.userTitle, "My Snippet")
    }

    func testUpdateClipTitleClearsWithNil() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("hello")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        try db.updateClipTitle(id: clipID, userTitle: "Temporary")
        try db.updateClipTitle(id: clipID, userTitle: nil)

        let loaded = try XCTUnwrap(db.allClips().first)
        XCTAssertNil(loaded.userTitle, "clearing title returns to nil")
    }

    // MARK: - displayTitle fallback logic

    func testDisplayTitleUsesUserTitleWhenSet() {
        var clip = makeTextClip("content")
        clip.sourceAppName = "Safari"
        clip.userTitle = "Useful Link"
        XCTAssertEqual(clip.displayTitle, "Useful Link")
    }

    func testDisplayTitleFallsBackToSourceAppName() {
        var clip = makeTextClip("content")
        clip.sourceAppName = "Safari"
        clip.userTitle = nil
        XCTAssertEqual(clip.displayTitle, "Safari")
    }

    func testDisplayTitleFallsBackToUnknownAppWhenBothNil() {
        var clip = makeTextClip("content")
        clip.sourceAppName = nil
        clip.userTitle = nil
        XCTAssertEqual(clip.displayTitle, "Unknown app")
    }

    // MARK: - FTS searches userTitle

    func testFTSMatchesUserTitle() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("generic content")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        try db.updateClipTitle(id: clipID, userTitle: "Quarterly Report")

        let results = try db.searchClips(matching: "Quarterly", limit: 10)
        XCTAssertEqual(results.count, 1, "FTS must find clips by their userTitle")
        XCTAssertEqual(results[0].id, clipID)
    }

    // MARK: - Category styling helper (pure logic, no UI)

    func testFirstCategoryReturnsLowestSortOrder() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("test")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        let alpha = try db.createCategory(
            named: "Alpha", colorHex: "#FF0000", iconKind: .symbol, iconValue: "star"
        )
        let beta = try db.createCategory(
            named: "Beta", colorHex: "#00FF00", iconKind: .symbol, iconValue: "circle"
        )
        let alphaID = try XCTUnwrap(alpha.id)
        let betaID = try XCTUnwrap(beta.id)

        // File the clip into both categories; Alpha has lower sortOrder (created first).
        try db.setClip(clipID, inCategory: alphaID, true)
        try db.setClip(clipID, inCategory: betaID, true)

        let categories = try db.categories()
        let membership = try db.membershipMap()
        let ids = membership[clipID] ?? []

        // firstCategory logic: first element of categories array that the clip belongs to.
        let first = categories.first { $0.id.map { ids.contains($0) } ?? false }
        XCTAssertEqual(first?.name, "Alpha", "first category must be the lowest sortOrder one")
    }
}
