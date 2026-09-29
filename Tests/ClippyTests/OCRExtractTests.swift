import XCTest
@testable import Clippy

/// Regression tests for Extract Text (OCR): the store-owned in-flight set
/// (double-run guard), single-insert behavior, and pasteboard self-write
/// suppression. See docs/CHANGELOG.md "Unreleased".
///
/// Vision is deliberately NOT called: a cold Vision call can take ~24s (or fail
/// without models) on a CI runner. The store's recognizer seam is stubbed so
/// these run deterministically everywhere; real Vision is exercised manually.
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
        var secondMessage: String?

        // Fire back-to-back: the second call must hit the in-flight guard
        // while the first recognition is still running.
        store.extractText(from: clip) { _ in first.fulfill() }
        store.extractText(from: clip) { message in
            secondMessage = message
            second.fulfill()
        }
        // Recognition is still gated, so the guard (not completion) answered.
        gate.signal()
        wait(for: [first, second], timeout: 10)

        XCTAssertTrue(
            secondMessage?.lowercased().contains("already running") == true,
            "second call should report already running, got: \(secondMessage ?? "nil")")
        let ocrRows = try db.allClips().filter { $0.sourceAppName == "Clippy OCR" }
        XCTAssertEqual(ocrRows.count, 1, "double click must not insert two OCR rows")
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

    func testOCRResultWriteIsNotRecaptured() throws {
        let db = try makeTestDatabase(self)
        // Scratch pasteboard so the test never touches the real clipboard;
        // ClipStore and the monitor must observe the SAME pasteboard for the
        // suppression to be observable. The board is never seeded: the only
        // change it ever sees is the OCR result write itself, and captures
        // write to the DB asynchronously, so seeding would race the counts.
        let scratch = NSPasteboard(name: NSPasteboard.Name("ClippyOCRTest-\(UUID().uuidString)"))
        let monitor = ClipboardMonitor(database: db, pasteboard: scratch)
        // Open the gate up front. (Initial value must stay 0: libdispatch traps
        // if a semaphore is deallocated with a value below its initial value.)
        let gate = DispatchSemaphore(value: 0)
        gate.signal()
        let store = ClipStore(
            database: db, monitor: monitor, pasteboard: scratch,
            recognizer: gatedRecognizer(gate: gate))
        let clip = try makeSavedImageClip(in: db)
        let rowsBefore = try db.allClips().count

        let done = expectation(description: "extraction finished")
        store.extractText(from: clip) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)

        // Drive the monitor through the change the OCR write produced.
        monitor.tick()
        monitor.tick()

        XCTAssertEqual(
            try db.allClips().count, rowsBefore + 1,
            "only the OCR insert may appear; the pasteboard write must not be re-captured")
        XCTAssertEqual(
            try db.allClips().filter { $0.sourceAppName == "Clippy OCR" }.count, 1)
    }
}
