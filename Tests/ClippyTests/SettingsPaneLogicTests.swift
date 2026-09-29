import XCTest
@testable import Clippy

final class SettingsPaneLogicTests: XCTestCase {
    func testRetentionRejectsBadInput() throws {
        var model = RetentionRuleEditorModel(rules: RetentionRules())
        XCTAssertThrowsError(try model.setForgetAfter(days: 0)) { XCTAssertEqual($0 as? RetentionRuleEditorModel.EditError, .daysOutOfRange) }
        XCTAssertThrowsError(try model.addAppRule(bundleID: "  ", days: 5)) { XCTAssertEqual($0 as? RetentionRuleEditorModel.EditError, .emptyAppID) }
        try model.addAppRule(bundleID: "com.apple.Terminal", days: 5)
        XCTAssertThrowsError(try model.addAppRule(bundleID: "com.apple.Terminal", days: 9)) { XCTAssertEqual($0 as? RetentionRuleEditorModel.EditError, .duplicate) }
        try model.addKindRule(kind: .image, days: 3)
        XCTAssertEqual(model.kindRows.first?.days, 3)
        model.removeAppRule("com.apple.Terminal")
        XCTAssertTrue(model.appRows.isEmpty)
        XCTAssertTrue(model.hasAnyRule)
    }

    func testBackupRowsNewestFirst() {
        let old = BackupSnapshot(url: URL(fileURLWithPath: "/tmp/a"), createdAt: Date(timeIntervalSince1970: 100), databaseBytes: 10)
        let new = BackupSnapshot(url: URL(fileURLWithPath: "/tmp/b"), createdAt: Date(timeIntervalSince1970: 200), databaseBytes: 20)
        XCTAssertEqual(BackupListModel.rows(from: [old, new]).map(\.id), ["b", "a"])
    }

    func testRestoreRequiresConfirmation() {
        var state = RestoreConfirmationState()
        XCTAssertNil(state.confirm())
        state.request("x")
        state.request("y")
        XCTAssertEqual(state.pendingID, "x")
        state.cancel()
        XCTAssertEqual(state.phase, .idle)
        state.request("x")
        XCTAssertEqual(state.confirm(), "x")
        XCTAssertTrue(state.isBusy)
        state.finish(error: "boom")
        XCTAssertEqual(state.phase, .failed("boom"))
        state.acknowledge()
        XCTAssertEqual(state.phase, .idle)
    }

    func testLanguageListFallbackAndToggle() {
        XCTAssertEqual(OCRLanguageList.supported(query: { nil }).map(\.code), OCRLanguageList.fallback.sorted())
        XCTAssertEqual(OCRLanguageList.supported(query: { ["fr-FR", "en-US", "fr-FR"] }).map(\.code), ["en-US", "fr-FR"])
        XCTAssertEqual(OCRLanguageList.toggled("de-DE", in: ["en-US"]), ["en-US", "de-DE"])
        XCTAssertEqual(OCRLanguageList.toggled("en-US", in: ["en-US"]), [])
    }

    func testDiagnosticsRows() {
        let now = Date()
        let fast = ContextReaderStats.HostTiming(bundleID: "a", samples: 3, lastMillis: 5, averageMillis: 5, maxMillis: 9, consecutiveTimeouts: 0, skippedUntil: nil)
        let slow = ContextReaderStats.HostTiming(bundleID: "b", samples: 3, lastMillis: 300, averageMillis: 300, maxMillis: 400, consecutiveTimeouts: 3,
                                                 skippedUntil: now.addingTimeInterval(300))
        let rows = DiagnosticsRowFormatter.rows(from: [fast, slow], now: now)
        XCTAssertEqual(rows.map(\.bundleID), ["b", "a"])
        XCTAssertEqual(rows[0].skippedText, "Yes, 5 min left")
        XCTAssertEqual(rows[1].skippedText, "No")
    }

    func testSmartCollectionDraftValidation() throws {
        var draft = SmartCollectionDraft()
        XCTAssertThrowsError(try draft.makeRule())
        draft.name = "Old images"
        draft.kinds = [.image]
        draft.olderThanDays = "abc"
        XCTAssertThrowsError(try draft.makeRule()) { XCTAssertEqual($0 as? SmartCollectionError, .invalidDays) }
        draft.olderThanDays = "30"
        XCTAssertEqual(try draft.makeRule().olderThanDays, 30)
    }
}
