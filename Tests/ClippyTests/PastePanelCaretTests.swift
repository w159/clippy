import AppKit
import XCTest
@testable import Clippy

final class PastePanelCaretTests: XCTestCase {
    func testCaretRangeIsCollapsedAtEnd() {
        XCTAssertEqual(PastePanel.caretRange(forFieldEditorLength: 4), NSRange(location: 4, length: 0))
        XCTAssertEqual(PastePanel.caretRange(forFieldEditorLength: 0), NSRange(location: 0, length: 0))
        XCTAssertEqual(PastePanel.caretRange(forFieldEditorLength: -1), NSRange(location: 0, length: 0))
    }
}
