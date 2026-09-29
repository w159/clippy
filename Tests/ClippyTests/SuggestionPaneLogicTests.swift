import XCTest
@testable import Clippy

final class SuggestionPaneLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: INT-05 embed text

    func testEmbedTextIncludesOCRTextAndFileName() {
        var image = makeIntelClip(1, "", now: now)
        image.ocrText = "  Invoice total due Friday  "
        XCTAssertEqual(SuggestionEngine.embedText(for: image), "Invoice total due Friday")

        var file = makeIntelClip(2, "", now: now)
        file.filePath = "/Users/x/Docs/Q3_report-final.pdf"
        file.contentKind = .file
        XCTAssertEqual(SuggestionEngine.embedText(for: file), "Q3 report final pdf")
    }

    func testClipWithoutAnyTextStaysEmpty() {
        var image = makeIntelClip(3, "", now: now)
        image.userTitle = "Title only"
        XCTAssertEqual(SuggestionEngine.embedText(for: image), "")
    }

    private func imageClip(_ id: Int64, ocr: String?, age: TimeInterval = 60) -> Clip {
        var clip = makeIntelClip(id, "", age: age, now: now)
        clip.contentKind = .image
        clip.mediaFilename = "img-\(id).png"
        clip.ocrText = ocr
        return clip
    }

    private var stubEngine: SuggestionEngine {
        SuggestionEngine(embedder: LanguageStubEmbedder(), dismissals: SuggestionDismissals(fileURL: nil))
    }

    func testOCRClipRelatesToMatchingQuery() {
        let image = imageClip(4, ocr: "quarterly invoice payment overdue")
        let other = makeIntelClip(5, "lisbon itinerary hotel booking", now: now)
        let seed = makeIntelClip(6, "quarterly invoice payment reminder", now: now)
        let ids = stubEngine.related(to: seed, clips: [image, other], limit: 5, now: now).map(\.id)
        XCTAssertEqual(ids.first, 4)
    }

    func testOCRClipBeatsSameRecencyNonMatchInRank() {
        let matching = imageClip(4, ocr: "quarterly invoice payment overdue", age: 60)
        let unrelated = imageClip(5, ocr: "lisbon itinerary hotel booking", age: 60)
        let context = ScreenContext(
            appName: "Notes", bundleID: "com.other", text: "quarterly invoice payment reminder", capturedAt: now)
        let ids = stubEngine.rank(context: context, clips: [unrelated, matching], limit: 5, now: now).map(\.id)
        XCTAssertEqual(ids.first, 4)
    }

    func testFileClipMatchesByFileName() {
        var file = makeIntelClip(7, "", now: now)
        file.contentKind = .file
        file.filePath = "/Users/x/Docs/quarterly_invoice-payment.pdf"
        var other = makeIntelClip(8, "", now: now)
        other.contentKind = .file
        other.filePath = "/Users/x/Docs/lisbon_itinerary-hotel.pdf"
        let context = ScreenContext(
            appName: "Notes", bundleID: "com.other", text: "quarterly invoice payment reminder", capturedAt: now)
        XCTAssertEqual(stubEngine.rank(context: context, clips: [other, file], limit: 5, now: now).first?.id, 7)
    }

    func testImageWithoutTextStillRanksOnRecencyAndApp() {
        let plain = imageClip(9, ocr: nil, age: 30)
        let context = ScreenContext(
            appName: "Notes", bundleID: "com.example.test", text: "quarterly invoice payment reminder", capturedAt: now)
        let ranked = stubEngine.rank(context: context, clips: [plain], limit: 5, now: now)
        XCTAssertEqual(ranked.map(\.id), [9])
        XCTAssertNil(ranked.first?.embeddingLanguage)
    }

    // MARK: INT-07 feedback

    func testFeedbackActionsAffectEngineAndUndo() {
        let dismissals = SuggestionDismissals(fileURL: nil)
        let feedback = SuggestionFeedback(dismissals: dismissals)
        let engine = SuggestionEngine(embedder: LanguageStubEmbedder(), dismissals: dismissals)
        let clip = makeIntelClip(1, "quarterly invoice payment overdue", now: now)
        let context = ScreenContext(appName: "Notes", bundleID: "com.other", text: "quarterly invoice payment", capturedAt: now)
        func ranked() -> [Int64] { engine.rank(context: context, clips: [clip], limit: 5, now: now).map(\.id) }
        XCTAssertEqual(ranked(), [1])
        feedback.apply(.neverSuggest, to: clip)
        XCTAssertTrue(ranked().isEmpty)
        feedback.undo(.neverSuggest, for: clip)
        XCTAssertEqual(ranked(), [1])

        let exclude = SuggestionFeedback.excludeAppAction(for: clip)
        XCTAssertEqual(exclude, .excludeApp(bundleID: "com.example.test", appName: "TestApp"))
        feedback.apply(exclude!, to: clip)
        XCTAssertEqual(dismissals.excludedApps(), ["com.example.test"])
        feedback.undo(exclude!, for: clip)
        XCTAssertTrue(dismissals.excludedApps().isEmpty)
    }

    // MARK: INT-01 / INT-08 diagnostics

    func testDiagnosticsNeverContainScreenText() {
        let secret = "SECRET-SCREEN-TEXT"
        let context = ScreenContext(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "w", text: secret, capturedAt: now)
        let log = ContextCaptureLog()
        log.record(appName: context.appName, bundleID: context.bundleID, textCharacters: context.text.count, elapsed: 0.042, now: now)
        let timing = ContextReaderStats.HostTiming(
            bundleID: "com.apple.mail", samples: 3, lastMillis: 42, averageMillis: 40, maxMillis: 60,
            consecutiveTimeouts: 0, skippedUntil: nil)
        let diag = SuggestionDiagnostics(capture: log.last, timings: [timing], now: now)
        XCTAssertFalse(diag.copyText.contains(secret))
        XCTAssertTrue(diag.copyText.contains("Yes (18 characters)"))
        XCTAssertTrue(diag.copyText.contains("42 ms"))
        XCTAssertTrue(diag.copyText.contains("Average: 40 ms"))
        XCTAssertNil(diag.skipMessage)
    }

    func testNoTextAndSkipState() {
        let entry = ContextCaptureLog.Entry(appName: "Slack", bundleID: "com.slack", textCharacters: nil, elapsedMillis: 260, capturedAt: now)
        let skipped = ContextReaderStats.HostTiming(
            bundleID: "com.slack", samples: 3, lastMillis: 260, averageMillis: 260, maxMillis: 270,
            consecutiveTimeouts: 3, skippedUntil: now.addingTimeInterval(600))
        let diag = SuggestionDiagnostics(capture: entry, timings: [skipped], now: now)
        XCTAssertEqual(diag.textReadLabel, "No")
        XCTAssertEqual(diag.skipMessage, "Skipped for 10 min: slow app")
        XCTAssertEqual(
            SuggestionsPaneMode.resolve(state: .empty, hasSuggestions: false, diagnostics: diag),
            .skipped(message: "Skipped for 10 min: slow app"))
        XCTAssertEqual(
            SuggestionsPaneMode.resolve(state: .ready, hasSuggestions: true, diagnostics: diag), .list)
        XCTAssertEqual(
            SuggestionsPaneMode.resolve(state: .needsPermission, hasSuggestions: false, diagnostics: diag),
            .needsPermission)
    }

    func testEmptyDiagnosticsHasPlaceholderRow() {
        let diag = SuggestionDiagnostics(capture: nil, timings: [], now: now)
        XCTAssertEqual(diag.rows.count, 1)
        XCTAssertEqual(SuggestionsPaneMode.resolve(state: .empty, hasSuggestions: false, diagnostics: diag), .empty)
    }
}
