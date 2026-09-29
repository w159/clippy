import XCTest
@testable import Clippy

final class ScriptsOnePasswordLogicTests: XCTestCase {
    func testTOTPCountdownWrapsAtPeriodBoundary() {
        let beforeBoundary = Date(timeIntervalSince1970: 59)
        let boundary = Date(timeIntervalSince1970: 60)
        XCTAssertEqual(TOTPCountdown.secondsRemaining(at: beforeBoundary), 1)
        XCTAssertEqual(TOTPCountdown.secondsRemaining(at: boundary), 30)
        XCTAssertEqual(TOTPCountdown.windowIndex(at: beforeBoundary), 1)
        XCTAssertEqual(TOTPCountdown.windowIndex(at: boundary), 2)
        XCTAssertEqual(TOTPCountdown.fractionRemaining(at: boundary), 1)
    }

    func testTOTPCountdownHandlesInvalidPeriodAndGroupsCodes() {
        XCTAssertEqual(TOTPCountdown.secondsRemaining(at: Date(timeIntervalSince1970: 4), period: 0), 1)
        XCTAssertEqual(TOTPCountdown.grouped("123456"), "123 456")
        XCTAssertEqual(TOTPCountdown.grouped("12345678"), "1234 5678")
        XCTAssertEqual(TOTPCountdown.grouped("12AB56"), "12AB56")
    }

    func testRunChipMapsEveryTerminalOutcome() {
        XCTAssertEqual(ScriptRunChipModel.model(for: nil).kind, .running)
        let success = ScriptResult(stdout: "ok", stderr: "", exitCode: 0, durationMs: 300, timedOut: false)
        let failure = ScriptResult(stdout: "", stderr: "bad", exitCode: 2, durationMs: 1200, timedOut: false)
        let cancelled = ScriptResult(stdout: "", stderr: "", exitCode: 143, durationMs: 5, timedOut: false, cancelled: true)
        let timedOut = ScriptResult(stdout: "", stderr: "", exitCode: 124, durationMs: 5000, timedOut: true)
        XCTAssertEqual(ScriptRunChipModel.model(for: success).title, "Success")
        XCTAssertEqual(ScriptRunChipModel.model(for: success).duration, "300 ms")
        XCTAssertEqual(ScriptRunChipModel.model(for: failure).kind, .failed)
        XCTAssertEqual(ScriptRunChipModel.model(for: failure).title, "Failed (exit 2)")
        XCTAssertEqual(ScriptRunChipModel.model(for: cancelled).kind, .cancelled)
        XCTAssertEqual(ScriptRunChipModel.model(for: timedOut, timeoutSeconds: 5).title, "Timed out after 5 s")
    }

    func testDrawerHeightKeepsEditorAndDrawerMinimums() {
        XCTAssertEqual(OutputDrawerMetrics.clamp(20, available: 500), OutputDrawerMetrics.minHeight)
        XCTAssertEqual(OutputDrawerMetrics.clamp(900, available: 500), 340)
        XCTAssertEqual(OutputDrawerMetrics.height(start: 200, translation: -40, available: 500), 240)
        XCTAssertEqual(OutputDrawerMetrics.clamp(.infinity, available: 500), OutputDrawerMetrics.defaultHeight)
    }

    func testBatchSelectionUsesVisibleOrderAndShrinksFromAnchor() {
        let ids = (0..<4).map { _ in UUID() }
        var selection = ScriptBatchSelection()
        selection.select(ids[1])
        selection.extend(to: ids[3], in: ids)
        XCTAssertEqual(selection.ordered(in: ids), Array(ids[1...3]))
        selection.extend(to: ids[2], in: ids)
        XCTAssertEqual(selection.ordered(in: ids), Array(ids[1...2]))
        selection.toggle(ids[0])
        XCTAssertEqual(selection.ordered(in: ids), [ids[0], ids[1], ids[2]])
        selection.extend(to: ids[2], in: ids)
        XCTAssertEqual(selection.ordered(in: ids), [ids[1], ids[2]])
    }

    func testOnePasswordSearchMatchesTitleAndVaultButNotFields() {
        let items = [
            OPItem(id: "1", title: "GitHub", category: "LOGIN", updatedAt: nil),
            OPItem(id: "2", title: "AWS Root", category: "PASSWORD", updatedAt: nil),
        ]
        XCTAssertEqual(OnePasswordFilter.filter(items, query: "github", vault: "Private").map(\.id), ["1"])
        XCTAssertEqual(OnePasswordFilter.filter(items, query: "private", vault: "Private").count, 2)
        XCTAssertTrue(OnePasswordFilter.filter(items, query: "password-value", vault: "Private").isEmpty)
    }
}
