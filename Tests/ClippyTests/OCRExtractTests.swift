import XCTest
@testable import Clippy

/// Regression tests for Extract Text (OCR): the store-owned in-flight set
/// (double-run guard) and OCR-01: extraction returns text through its outcome
/// and NEVER writes the pasteboard or database implicitly. See docs/CHANGELOG.md "Unreleased".
///
/// Vision is deliberately NOT called: a cold Vision call can take ~24s (or fail
/// without models) on a CI runner. The store's recognizer seam is stubbed so
/// these run deterministically everywhere; real Vision is exercised manually.
@MainActor
final class OCRExtractTests: XCTestCase {

    /// Stub recognizer that behaves like `OCRService.recognizeText`: work off
    /// the main thread, completion on main. It blocks on `gate` so a test can
    /// hold recognition "in flight" for exactly as long as it needs.
    private func gatedRecognizer(
        gate: DispatchSemaphore, text: String = "stub ocr text"
    ) -> (URL, @escaping (OCRService.RecognitionResult) -> Void) -> Void {
        { _, completion in
            DispatchQueue.global().async {
                gate.wait()
                DispatchQueue.main.async { completion(.success(text)) }
            }
        }
    }

    /// Small PNG with text Vision can recognize. Rendering uses NSImage, so
    /// this must run on the main thread (XCTest default).
    private func makeTextPNGData() -> Data {
        let size = NSSize(width: 400, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: "Clippy OCR test 123")
            .draw(at: NSPoint(x: 16, y: 44), withAttributes: attrs)
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// Persists an image clip and returns the STORED row (with its row id),
    /// matching production: extractText is always called with store-loaded
    /// clips. upsertCaptured does not write the assigned id back to the value
    /// passed in, so re-fetching is required.
    private func makeSavedImageClip(in db: ClipDatabase) throws -> Clip {
        let stored = try db.media.store(pngData: makeTextPNGData())
        var clip = makeImageClip(stored)
        try db.saveCapturedImageClip(&clip, cap: 1000)
        let saved = try db.allClips().first { $0.mediaFilename == stored.mediaFilename }
        return try XCTUnwrap(saved, "saved image clip should be fetchable with its row id")
    }

    func testDoubleRunGuardPreventsDuplicateOCRInserts() throws {
        let db = try makeTestDatabase(self)
        let clip = try makeSavedImageClip(in: db)
        XCTAssertNotNil(clip.id)
        // Scratch pasteboard: the successful OCR write must not clobber the
        // developer's real clipboard during test runs.
        let scratch = NSPasteboard(name: NSPasteboard.Name("ClippyOCRTest-\(UUID().uuidString)"))
        let gate = DispatchSemaphore(value: 0)
        let store = ClipStore(
            database: db, pasteboard: scratch, recognizer: gatedRecognizer(gate: gate))

        let first = expectation(description: "first extraction")
        let second = expectation(description: "guarded second extraction")
        var secondOutcome: OCRExtractOutcome?

        // Fire back-to-back: the second call must hit the in-flight guard
        // while the first recognition is still running.
        store.extractText(from: clip) { _ in first.fulfill() }
        store.extractText(from: clip) { outcome in
            secondOutcome = outcome
            second.fulfill()
        }
        // Recognition is still gated, so the guard (not completion) answered.
        gate.signal()
        wait(for: [first, second], timeout: 10)

        XCTAssertEqual(
            secondOutcome, .notice("Text extraction is already running for this clip."),
            "second call should report already running")
        let ocrRows = try db.allClips().filter { $0.sourceAppName == "Clippy OCR" }
        XCTAssertEqual(ocrRows.count, 0, "extraction must not insert rows implicitly")
        XCTAssertTrue(store.ocrInFlightClipIDs.isEmpty, "in-flight set must drain")
    }

    func testInFlightSetPopulatesAndDrains() throws {
        let db = try makeTestDatabase(self)
        let clip = try makeSavedImageClip(in: db)
        let scratch = NSPasteboard(name: NSPasteboard.Name("ClippyOCRTest-\(UUID().uuidString)"))
        let gate = DispatchSemaphore(value: 0)
        let store = ClipStore(
            database: db, pasteboard: scratch, recognizer: gatedRecognizer(gate: gate))

        let done = expectation(description: "extraction finished")
        store.extractText(from: clip) { _ in done.fulfill() }
        // extractText inserts the id synchronously before dispatching the
        // background recognition; the completion can only hop back to this
        // queue later, so the set is observable right here.
        XCTAssertFalse(
            store.ocrInFlightClipIDs.isEmpty,
            "in-flight set should be populated during recognition")
        gate.signal()
        wait(for: [done], timeout: 10)
        XCTAssertTrue(store.ocrInFlightClipIDs.isEmpty, "in-flight set must drain after completion")
    }

    func testExtractReturnsTextWithoutTouchingPasteboardOrDatabase() throws {
        let db = try makeTestDatabase(self)
        let scratch = NSPasteboard(name: NSPasteboard.Name("ClippyOCRTest-\(UUID().uuidString)"))
        scratch.clearContents()
        scratch.setString("user clipboard", forType: .string)
        let changeBefore = scratch.changeCount
        let gate = DispatchSemaphore(value: 0)
        gate.signal()
        let store = ClipStore(
            database: db, pasteboard: scratch, recognizer: gatedRecognizer(gate: gate, text: "  hello world \n"))
        let clip = try makeSavedImageClip(in: db)
        let rowsBefore = try db.allClips().count

        let done = expectation(description: "extraction finished")
        var outcome: OCRExtractOutcome?
        store.extractText(from: clip) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(outcome, .text("hello world"))
        XCTAssertEqual(scratch.changeCount, changeBefore, "OCR must not write the pasteboard")
        XCTAssertEqual(scratch.string(forType: .string), "user clipboard")
        XCTAssertEqual(try db.allClips().count, rowsBefore, "OCR must not insert a clip")
    }

    func testWhitespaceOnlyResultIsNoticeNotText() throws {
        let db = try makeTestDatabase(self)
        let gate = DispatchSemaphore(value: 0)
        gate.signal()
        let store = ClipStore(database: db, recognizer: gatedRecognizer(gate: gate, text: " \n\t "))
        let clip = try makeSavedImageClip(in: db)
        let done = expectation(description: "done")
        var outcome: OCRExtractOutcome?
        store.extractText(from: clip) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .notice("No text found in image."))
    }

    func testSaveOCRTextIsExplicitAndSingleInsert() throws {
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        try store.saveOCRText("saved on request")
        let rows = try db.allClips().filter { $0.sourceAppName == "Clippy OCR" }
        XCTAssertEqual(rows.map(\.contentText), ["saved on request"])
    }

    func testCancelledRunPresentsNothing() throws {
        let db = try makeTestDatabase(self)
        let clip = try makeSavedImageClip(in: db)
        let gate = DispatchSemaphore(value: 0)
        let store = ClipStore(database: db, recognizer: gatedRecognizer(gate: gate))
        let done = expectation(description: "done")
        var outcome: OCRExtractOutcome?
        store.extractText(from: clip) { outcome = $0; done.fulfill() }
        store.cancelOCR(for: try XCTUnwrap(clip.id))
        gate.signal()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .notice("Text extraction was cancelled."))
    }
}
