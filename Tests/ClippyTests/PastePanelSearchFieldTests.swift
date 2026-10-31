import AppKit
import XCTest
@testable import Clippy

@MainActor
final class PastePanelSearchFieldTests: XCTestCase {
    private func field(y: CGFloat, placeholder: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: y, width: 100, height: 20))
        field.isEditable = true
        field.placeholderString = placeholder
        return field
    }

    func testFindsSearchFieldByPlaceholderNotPosition() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let search = field(y: 10, placeholder: "Search clips")
        let other = field(y: 300, placeholder: "Ask anything")
        root.addSubview(other)
        root.addSubview(search)
        XCTAssertTrue(PastePanel.searchField(in: root) === search)
    }

    func testFallsBackToTopmostEditableField() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let top = field(y: 350, placeholder: "")
        let low = field(y: 20, placeholder: "")
        root.addSubview(low)
        root.addSubview(top)
        XCTAssertTrue(PastePanel.searchField(in: root) === top)
    }

    func testNoEditableFieldReturnsNil() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        root.addSubview(NSTextField(labelWithString: "Search clips"))
        XCTAssertNil(PastePanel.searchField(in: root))
    }
}
