import XCTest
@testable import Clippy

final class EditorStatusMetricsTests: XCTestCase {
    func testCaretLineAndColumnAreOneBased() {
        let snap = EditorStatusMetrics.snapshot(text: "ab\ncde\nf", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(snap.line, 2)
        XCTAssertEqual(snap.column, 3)
        XCTAssertEqual(snap.lines, 3)
        XCTAssertEqual(snap.caretLabel, "Ln 2, Col 3")
    }

    func testEmptyTextHasZeroLinesAndOriginCaret() {
        let snap = EditorStatusMetrics.snapshot(text: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual([snap.line, snap.column, snap.characters, snap.lines], [1, 1, 0, 0])
    }

    func testEmojiCountsOneCharacterButTwoUTF16Units() {
        let text = "a👍🏽b"
        let snap = EditorStatusMetrics.snapshot(text: text, selection: NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(snap.characters, 3)
        XCTAssertEqual(snap.utf16Units, text.utf16.count)
        XCTAssertGreaterThan(snap.utf16Units, 3)
        XCTAssertEqual(snap.column, 4)
    }

    func testCaretInsideSurrogatePairRoundsDownToBoundary() {
        let snap = EditorStatusMetrics.snapshot(text: "a😀b", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(snap.column, 2)
    }

    func testSelectionClampedAndCountedInGraphemes() {
        let snap = EditorStatusMetrics.snapshot(text: "e\u{301}xy", selection: NSRange(location: 0, length: 999))
        XCTAssertEqual(snap.selectedCharacters, 3)
        XCTAssertEqual(snap.characters, 3)
        XCTAssertEqual(snap.caretLabel, "Ln 1, Col 1 (3 selected)")
    }

    func testCRLFCountsAsOneLineBreak() {
        let snap = EditorStatusMetrics.snapshot(text: "a\r\nb", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(snap.line, 2)
        XCTAssertEqual(snap.column, 2)
    }

    func testSingularCharacterLabel() {
        XCTAssertEqual(EditorStatusMetrics.snapshot(text: "x", selection: NSRange(location: 0, length: 0)).characterLabel, "1 char")
    }
}
