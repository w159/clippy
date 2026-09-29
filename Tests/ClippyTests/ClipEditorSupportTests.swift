import XCTest
@testable import Clippy

@MainActor
final class ClipEditorSupportTests: XCTestCase {
    // MARK: Conflict detection

    func testConflictEvaluation() {
        XCTAssertEqual(EditorConflictDetector.evaluate(base: "a", mine: "b", stored: "a"), .unchanged)
        XCTAssertEqual(EditorConflictDetector.evaluate(base: "a", mine: "a", stored: "c"), .reload)
        XCTAssertEqual(EditorConflictDetector.evaluate(base: "a", mine: "b", stored: "c"), .conflict)
        XCTAssertEqual(EditorConflictDetector.evaluate(base: "a", mine: "b", stored: "b"), .adoptBase)
    }

    // MARK: Single-transaction save

    func testSaveWritesTextAndTitleTogether() throws {
        let db = try makeTestDatabase(self)
        let id = try db.insertTextClip("original")
        let persistence = ClipEditorPersistence(database: db)
        try persistence.save(id: id, text: "edited", title: "  My title ")
        let clip = try XCTUnwrap(persistence.fetch(id: id))
        XCTAssertEqual(clip.contentText, "edited")
        XCTAssertEqual(clip.userTitle, "My title")
    }

    func testSaveOnlyTouchesChangedFieldsAndClearsBlankTitle() throws {
        let db = try makeTestDatabase(self)
        let id = try db.insertTextClip("original")
        let persistence = ClipEditorPersistence(database: db)
        try persistence.save(id: id, text: nil, title: "Named")
        XCTAssertEqual(persistence.fetch(id: id)?.contentText, "original")
        try persistence.save(id: id, text: "new", title: nil)
        XCTAssertEqual(persistence.fetch(id: id)?.userTitle, "Named")
        try persistence.save(id: id, text: nil, title: "   ")
        XCTAssertNil(persistence.fetch(id: id)?.userTitle)
    }

    func testFetchMissingClipIsNil() throws {
        let persistence = ClipEditorPersistence(database: try makeTestDatabase(self))
        XCTAssertNil(persistence.fetch(id: 999))
    }

    // MARK: Drafts

    private func makeDraftStore() -> EditorDraftStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-drafts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return EditorDraftStore(fileURL: dir.appendingPathComponent("drafts.json"))
    }

    private func draft(_ id: Int64, _ text: String, at seconds: TimeInterval = 0) -> EditorDraft {
        EditorDraft(clipID: id, text: text, title: "t", baseText: "base",
                    savedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }

    func testDraftRoundTripReplacesPerClipAndRemoves() {
        let store = makeDraftStore()
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.save(draft(1, "one")))
        XCTAssertTrue(store.save(draft(2, "two", at: 5)))
        XCTAssertTrue(store.save(draft(1, "one v2", at: 10)))
        XCTAssertEqual(store.all().map(\.clipID), [2, 1])
        XCTAssertEqual(store.all().last?.text, "one v2")
        store.remove(clipID: 2)
        XCTAssertEqual(store.all().map(\.clipID), [1])
        store.remove(clipID: 1)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testCorruptDraftFileYieldsNoDraftsAndRecovers() throws {
        let store = makeDraftStore()
        XCTAssertTrue(store.save(draft(1, "x")))
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(store.save(draft(2, "y")))
        XCTAssertEqual(store.all().map(\.clipID), [2])
    }

    func testDraftFileIsOwnerOnly() throws {
        let store = makeDraftStore()
        XCTAssertTrue(store.save(draft(1, "secret")))
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: Crop geometry

    func testCropSelectionSurvivesResize() throws {
        let pixels = CGSize(width: 1000, height: 500)
        let small = CGSize(width: 200, height: 100)
        let start = try XCTUnwrap(CropSelection.imagePoint(fromView: CGPoint(x: 20, y: 10), fitted: small, pixels: pixels))
        let end = try XCTUnwrap(CropSelection.imagePoint(fromView: CGPoint(x: 100, y: 50), fitted: small, pixels: pixels))
        let rect = try XCTUnwrap(CropSelection.imageRect(from: start, to: end, fitted: small, pixels: pixels))
        XCTAssertEqual(rect, CGRect(x: 100, y: 50, width: 400, height: 200))
        let large = CGSize(width: 500, height: 250)
        XCTAssertEqual(CropSelection.viewRect(fromImage: rect, fitted: large, pixels: pixels),
                       CGRect(x: 50, y: 25, width: 200, height: 100))
    }

    func testCropSelectionClampsAndRejectsTinyDrags() throws {
        let pixels = CGSize(width: 100, height: 100)
        let fitted = CGSize(width: 100, height: 100)
        let outside = try XCTUnwrap(CropSelection.imagePoint(fromView: CGPoint(x: 500, y: -5), fitted: fitted, pixels: pixels))
        XCTAssertEqual(outside, CGPoint(x: 100, y: 0))
        XCTAssertNil(CropSelection.imageRect(from: .zero, to: CGPoint(x: 1, y: 50), fitted: fitted, pixels: pixels))
        XCTAssertNil(CropSelection.imagePoint(fromView: .zero, fitted: .zero, pixels: pixels))
    }

    // MARK: Window title and preference

    func testWindowTitleFallsBackByKind() {
        var clip = makeTextClip("hi")
        clip.userTitle = "Named"
        XCTAssertEqual(EditorWindowController.windowTitle(for: clip), "Named")
        clip.userTitle = "  "
        XCTAssertEqual(EditorWindowController.windowTitle(for: clip), "Edit Clip")
    }

    func testExternalEditorPreferencePersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "clippy-test-\(UUID().uuidString)"))
        XCTAssertNil(ExternalEditorPreference.bundleID(defaults: defaults))
        ExternalEditorPreference.setBundleID("com.example.editor", defaults: defaults)
        XCTAssertEqual(ExternalEditorPreference.bundleID(defaults: defaults), "com.example.editor")
        ExternalEditorPreference.setBundleID(nil, defaults: defaults)
        XCTAssertNil(ExternalEditorPreference.bundleID(defaults: defaults))
    }
}
