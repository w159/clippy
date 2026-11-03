import XCTest
import GRDB
@testable import Clippy

/// Failed storage writes and reads must reach the user instead of passing for
/// success or an empty result.
@MainActor
final class StoreErrorSurfacingTests: XCTestCase {
    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if condition() { timer.invalidate(); done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
        timer.invalidate()
    }

    private func execute(_ sql: String, on db: ClipDatabase) throws {
        try db.dbQueue.write { try $0.execute(sql: sql) }
    }

    // MARK: - performWrite

    func testFailedBackgroundWriteIsPublishedOnce() throws {
        let db = try makeTestDatabase(self)
        let clipID = try db.insertTextClip("pin me", sourceAppName: "Test")
        let category = try db.createCategory(named: "Work", colorHex: "#ff0000", iconKind: .symbol, iconValue: "star")
        let categoryID = try XCTUnwrap(category.id)
        try execute(
            "CREATE TRIGGER block_membership BEFORE INSERT ON clip_category BEGIN SELECT RAISE(ABORT, 'forced'); END",
            on: db)
        let store = ClipStore(database: db)
        XCTAssertNil(store.categoryError)

        store.addClip(id: clipID, toCategory: categoryID)

        waitFor("write failure published") { store.categoryError != nil }
        XCTAssertEqual(store.categoryError, ClipStore.writeFailureMessage)
        XCTAssertEqual(try db.membershipMap()[clipID] ?? [], [], "the failed write must not have been applied")
    }

    func testSuccessfulBackgroundWriteStaysSilent() throws {
        let db = try makeTestDatabase(self)
        let clipID = try db.insertTextClip("pin me", sourceAppName: "Test")
        let category = try db.createCategory(named: "Work", colorHex: "#ff0000", iconKind: .symbol, iconValue: "star")
        let categoryID = try XCTUnwrap(category.id)
        let store = ClipStore(database: db)

        store.addClip(id: clipID, toCategory: categoryID)

        waitFor("membership applied") { store.membership[clipID]?.contains(categoryID) == true }
        XCTAssertNil(store.categoryError)
    }

    // MARK: - Semantic search read

    func testFailedSemanticReadThrowsInsteadOfReturningNoCandidates() throws {
        let closed = try DatabaseQueue()
        try closed.close()
        XCTAssertThrowsError(try ClipStore.recentTextCandidates(from: closed))

        let db = try makeTestDatabase(self)
        _ = try db.insertTextClip("candidate", sourceAppName: "Test")
        XCTAssertEqual(try ClipStore.recentTextCandidates(from: db.dbQueue).map(\.contentText), ["candidate"])
    }

    func testSemanticFailureSetsSearchErrorOnlyForTheCurrentSearch() throws {
        let store = ClipStore(database: try makeTestDatabase(self))
        XCTAssertNil(store.searchError)

        store.reportSemanticFailure(token: store.refilterToken &+ 1)
        XCTAssertNil(store.searchError, "a stale search must not raise an error")

        store.reportSemanticFailure(token: store.refilterToken)
        XCTAssertNotNil(store.searchError)
    }

    // MARK: - Translate replace

    func testReplaceClipReportsFailureAndSuccess() throws {
        let db = try makeTestDatabase(self)
        let clipID = try db.insertTextClip("original", sourceAppName: "Test")
        let store = ClipStore(database: db)
        let sink = ClipStoreTranslateSink(store: store)

        XCTAssertTrue(sink.replaceClip(clipID, with: "translated"))
        XCTAssertEqual(try db.allClips().first { $0.id == clipID }?.contentText, "translated")

        try execute(
            "CREATE TRIGGER block_update BEFORE UPDATE ON clips BEGIN SELECT RAISE(ABORT, 'forced'); END", on: db)
        XCTAssertFalse(sink.replaceClip(clipID, with: "again"))
        XCTAssertEqual(try db.allClips().first { $0.id == clipID }?.contentText, "translated")
    }

    // MARK: - Undo

    func testUndoReportsCategoryRestoreFailures() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let db = try makeTestDatabase(self)
        let id = try db.insertTextClip("original", sourceAppName: "Test")
        let clip = try XCTUnwrap(try db.allClips().first { $0.id == id })
        let snap = DeletedClipSnapshot(clip: clip, categoryIDs: [9999], media: [:])
        let failures = Counter()

        XCTAssertEqual(try ClipUndoBuffer.restore([snap], into: db) { failures.value = $0 }, 1)
        XCTAssertEqual(failures.value, 1)
    }
}
