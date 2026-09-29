import Combine
import XCTest
@testable import Clippy

/// KEY-02 (search generation), OCR-04/05 (trim, existence, cancel, per-clip
/// progress), SBR-04 (existing names), DAT-14 (category errors surfaced),
/// DAT-06 (90% warning).
@MainActor
final class DataLayerStoreTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: StorageCeiling.defaultsKey)
        super.tearDown()
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if condition() { timer.invalidate(); done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
        timer.invalidate()
    }

    // MARK: - Search (KEY-02)

    func testClearingTheQueryDiscardsAnInFlightSearchResult() throws {
        let db = try makeTestDatabase(self)
        for index in 0..<20 {
            var clip = makeTextClip("needle \(index)")
            try db.saveCapturedClip(&clip, cap: 100)
        }
        let store = ClipStore(database: db)
        waitFor("initial load") { store.clips.count == 20 }

        store.query = "needle 7"
        waitFor("search applied") { store.clips.count == 1 }
        // Clear immediately, then give any late FTS completion time to land.
        store.query = ""
        XCTAssertEqual(store.clips.count, 20)
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(store.clips.count, 20, "a stale search result must not overwrite the cleared list")
    }

    func testNewerQueryWinsOverOlderOne() throws {
        let db = try makeTestDatabase(self)
        for text in ["alpha one", "beta two"] {
            var clip = makeTextClip(text)
            try db.saveCapturedClip(&clip, cap: 100)
        }
        let store = ClipStore(database: db)
        waitFor("initial") { store.clips.count == 2 }
        store.query = "alpha"
        store.query = "beta"
        waitFor("beta results") { store.clips.map(\.contentText) == ["beta two"] }
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(store.clips.map(\.contentText), ["beta two"])
    }

    // MARK: - Categories (SBR-04, DAT-14)

    func testExistingNamesExcludesTheCategoryBeingRenamed() throws {
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        let alpha = try store.tryCreateCategory(named: "Alpha", colorHex: "#1", iconKind: .symbol, iconValue: "a")
        try store.tryCreateCategory(named: "Beta", colorHex: "#2", iconKind: .symbol, iconValue: "b")
        waitFor("categories") { store.categories.count == 3 }
        XCTAssertTrue(store.existingCategoryNames().contains("Alpha"))
        XCTAssertFalse(store.existingCategoryNames(excluding: alpha).contains("Alpha"))
        XCTAssertTrue(store.existingCategoryNames(excluding: alpha).contains("Beta"))
    }

    func testCategoryFailuresAreSurfacedNotSwallowed() throws {
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        XCTAssertNotNil(store.createCategory(named: "Once", colorHex: "#1", iconKind: .symbol, iconValue: "a"))
        XCTAssertNil(store.categoryError)
        XCTAssertNil(store.createCategory(named: "once", colorHex: "#1", iconKind: .symbol, iconValue: "a"))
        XCTAssertEqual(store.categoryError, CategoryError.duplicateName("once").errorDescription)
        XCTAssertThrowsError(try store.tryCreateCategory(named: "ONCE", colorHex: "#1", iconKind: .symbol, iconValue: "a"))
    }

    // MARK: - Ceiling warning (DAT-06)

    func testStoreWarnsAtNinetyPercentOfTheConfiguredCeiling() throws {
        StorageCeiling.current = 100
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        XCTAssertNil(store.storageWarning)
        for index in 0..<90 { try db.insertTextClip("clip \(index)", cap: 0) }
        waitFor("warning published") { store.storageWarning != nil }
        XCTAssertEqual(store.storageWarning, StorageUsage(count: 90, ceiling: 100))
    }

    // MARK: - OCR (OCR-04/05/09)

    private func savedImageClip(_ db: ClipDatabase) throws -> Clip {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let stored = try db.media.store(pngData: MediaStore.pngData(from: image)!)
        var clip = makeImageClip(stored)
        try db.saveCapturedImageClip(&clip, cap: 100)
        return try XCTUnwrap(db.allClips().first { $0.mediaFilename == stored.mediaFilename })
    }

    private func scratchBoard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("DLTest-\(UUID().uuidString)")) }

    /// Recognizer whose completion the test releases by hand (on the main queue).
    private final class Deferred {
        var finish: ((OCRService.RecognitionResult) -> Void)?
        lazy var recognizer: (URL, @escaping (OCRService.RecognitionResult) -> Void) -> Void = { [unowned self] _, done in
            self.finish = done
        }
    }

    func testWhitespaceOnlyOCRResultIsNoTextAndInsertsNothing() throws {
        let db = try makeTestDatabase(self)
        let clip = try savedImageClip(db)
        let board = scratchBoard()
        let stub = Deferred()
        let store = ClipStore(database: db, pasteboard: board, recognizer: stub.recognizer)
        var message = ""
        store.extractText(from: clip) { message = $0.message }
        stub.finish?(.success("  \n\t  "))
        XCTAssertEqual(message, "No text found in image.")
        XCTAssertFalse(try db.allClips().contains { $0.sourceAppName == "Clippy OCR" })
        XCTAssertNil(board.string(forType: .string), "clipboard untouched")
    }

    func testOCRResultIsTrimmedAndOnlySavedOnExplicitSave() throws {
        let db = try makeTestDatabase(self)
        let clip = try savedImageClip(db)
        let board = scratchBoard()
        let stub = Deferred()
        let store = ClipStore(database: db, pasteboard: board, recognizer: stub.recognizer)
        var outcome: OCRExtractOutcome?
        store.extractText(from: clip) { outcome = $0 }
        stub.finish?(.success("\n  hello ocr \n"))
        XCTAssertEqual(outcome, .text("hello ocr"))
        XCTAssertFalse(
            try db.allClips().contains { $0.sourceAppName == "Clippy OCR" },
            "extraction must not insert a clip")
        XCTAssertNil(board.string(forType: .string), "extraction must not write the pasteboard")

        guard case .text(let text)? = outcome else { return XCTFail("expected recognized text") }
        try store.saveOCRText(text)
        let saved = try db.allClips().filter { $0.sourceAppName == "Clippy OCR" }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.contentText, "hello ocr")
    }

    func testOCRForADeletedClipWritesNothing() throws {
        let db = try makeTestDatabase(self)
        let clip = try savedImageClip(db)
        let board = scratchBoard()
        let stub = Deferred()
        let store = ClipStore(database: db, pasteboard: board, recognizer: stub.recognizer)
        var message = ""
        store.extractText(from: clip) { message = $0.message }
        try db.deleteClip(id: try XCTUnwrap(clip.id))
        stub.finish?(.success("late text"))
        XCTAssertTrue(message.contains("deleted"), message)
        XCTAssertFalse(try db.allClips().contains { $0.sourceAppName == "Clippy OCR" })
        XCTAssertNil(board.string(forType: .string))
    }

    func testCancelledOCRDiscardsItsResultAndFreesTheClip() throws {
        let db = try makeTestDatabase(self)
        let clip = try savedImageClip(db)
        let id = try XCTUnwrap(clip.id)
        let stub = Deferred()
        let store = ClipStore(database: db, pasteboard: scratchBoard(), recognizer: stub.recognizer)
        var message = ""
        store.extractText(from: clip) { message = $0.message }
        XCTAssertTrue(store.isOCRRunning(for: id))
        store.cancelOCR(for: id)
        XCTAssertFalse(store.isOCRRunning(for: id))
        XCTAssertTrue(store.ocrInFlightClipIDs.isEmpty)
        stub.finish?(.success("ignored"))
        XCTAssertTrue(message.contains("cancelled"))
        XCTAssertFalse(try db.allClips().contains { $0.sourceAppName == "Clippy OCR" })

        // The clip can be extracted again afterwards.
        var second = ""
        store.extractText(from: clip) { second = $0.message }
        stub.finish?(.success("second run"))
        XCTAssertTrue(second.contains("extracted"), second)
    }

    func testPerClipProgressInvalidatesOnlyTheAffectedClipsObserver() throws {
        let db = try makeTestDatabase(self)
        let clip = try savedImageClip(db)
        let id = try XCTUnwrap(clip.id)
        let stub = Deferred()
        let store = ClipStore(database: db, pasteboard: scratchBoard(), recognizer: stub.recognizer)

        var affectedChanges = 0
        var otherChanges = 0
        let affected = store.ocrProgress(for: id)
        let other = store.ocrProgress(for: id + 999)
        let subs = [affected.objectWillChange.sink { affectedChanges += 1 },
                    other.objectWillChange.sink { otherChanges += 1 }]

        store.extractText(from: clip) { _ in }
        XCTAssertTrue(affected.isRunning)
        XCTAssertGreaterThanOrEqual(affectedChanges, 1)
        XCTAssertEqual(otherChanges, 0, "an unrelated card's observable must not fire")
        stub.finish?(.success("done"))
        XCTAssertFalse(affected.isRunning)
        XCTAssertEqual(otherChanges, 0)
        withExtendedLifetime(subs) {}
    }
}
