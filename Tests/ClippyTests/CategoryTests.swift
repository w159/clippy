import XCTest
import GRDB
@testable import Clippy

@MainActor
final class CategoryTests: XCTestCase {
    func testMigrationCreatesStarterCategory() throws {
        let db = try makeTestDatabase(self)
        let starter = try db.starterCategory()
        XCTAssertEqual(starter?.name, "Pinned")
        XCTAssertTrue(starter?.isStarter == true)
    }

    func testLegacyPinnedClipsMigrateToStarterCategory() throws {
        // Build a v1 database by hand, mark a clip pinned, then run the
        // full migrator over it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try ClipDatabase.makeMigrator().migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, isPinned)
                    VALUES ('keep me', 'public.utf8-plain-text', ?, 1),
                           ('plain', 'public.utf8-plain-text', ?, 0)
                    """,
                arguments: [Date(), Date()]
            )
        }

        let migrated = try ClipDatabase(databaseURL: url)
        let starterID = try XCTUnwrap(migrated.starterCategory()?.id)
        let map = try migrated.membershipMap()
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.values.first, [starterID])
    }

    func testCategoryCRUDAndMembership() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("snippet")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        let work = try db.createCategory(
            named: "Work", colorHex: "#007AFF", iconKind: .symbol, iconValue: "briefcase.fill"
        )
        let workID = try XCTUnwrap(work.id)

        try db.setClip(clipID, inCategory: workID, true)
        XCTAssertEqual(try db.membershipMap()[clipID], [workID])

        var renamed = work
        renamed.name = "Job"
        try db.updateCategory(renamed)
        XCTAssertEqual(try db.categories().first(where: { $0.id == workID })?.name, "Job")

        // Deleting a category never deletes clips; junction rows cascade away.
        try db.deleteCategory(id: workID)
        XCTAssertNil(try db.membershipMap()[clipID])
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testMoveCategoryReorders() throws {
        let db = try makeTestDatabase(self)
        _ = try db.createCategory(named: "A", colorHex: "#111111", iconKind: .symbol, iconValue: "a.circle")
        let a = try XCTUnwrap(db.categories().first { $0.name == "A" }?.id)
        _ = try db.createCategory(named: "B", colorHex: "#222222", iconKind: .symbol, iconValue: "b.circle")
        _ = try db.createCategory(named: "C", colorHex: "#333333", iconKind: .symbol, iconValue: "c.circle")
        let c = try XCTUnwrap(db.categories().first { $0.name == "C" }?.id)

        // Order starts: Pinned, A, B, C. Move C before A -> Pinned, C, A, B.
        try db.moveCategory(id: c, before: a)
        XCTAssertEqual(try db.categories().map(\.name), ["Pinned", "C", "A", "B"])
    }

    func testDeletingStarterThenPinningRecreatesIt() throws {
        let db = try makeTestDatabase(self)
        let starterID = try XCTUnwrap(db.starterCategory()?.id)
        try db.deleteCategory(id: starterID)
        XCTAssertNil(try db.starterCategory())

        var clip = makeTextClip("pin me")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)

        // Cmd+P with no starter present must recreate one and pin into it.
        try db.toggleStarterMembership(clipID: clipID)
        let recreated = try XCTUnwrap(db.starterCategory())
        let recreatedID = try XCTUnwrap(recreated.id)
        XCTAssertEqual(recreated.name, "Pinned")
        XCTAssertEqual(try db.membershipMap()[clipID], [recreatedID])
    }

    func testToggleStarterMembership() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("pin me")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)
        let starterID = try XCTUnwrap(db.starterCategory()?.id)

        try db.toggleStarterMembership(clipID: clipID)
        XCTAssertEqual(try db.membershipMap()[clipID], [starterID])
        try db.toggleStarterMembership(clipID: clipID)
        XCTAssertNil(try db.membershipMap()[clipID])
    }
}
