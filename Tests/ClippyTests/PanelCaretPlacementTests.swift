import AppKit
import XCTest
@testable import Clippy

final class PanelCaretPlacementTests: XCTestCase {
    @MainActor
    func testCaretPlacementOnlyRefinesSmallStableFallback() {
        let initial = CGRect(x: 100, y: 100, width: 400, height: 500)
        let mouse = CGPoint(x: 200, y: 200)
        XCTAssertTrue(PanelController.shouldApplyCaretPlacement(
            initialFrame: initial, caretFrame: CGRect(x: 120, y: 110, width: 400, height: 500),
            initialMouse: mouse, currentMouse: mouse, interactionUnchanged: true))
        XCTAssertFalse(PanelController.shouldApplyCaretPlacement(
            initialFrame: initial, caretFrame: CGRect(x: 160, y: 110, width: 400, height: 500),
            initialMouse: mouse, currentMouse: mouse, interactionUnchanged: true))
        XCTAssertFalse(PanelController.shouldApplyCaretPlacement(
            initialFrame: initial, caretFrame: CGRect(x: 120, y: 110, width: 400, height: 500),
            initialMouse: mouse, currentMouse: CGPoint(x: 210, y: 200), interactionUnchanged: true))
        XCTAssertFalse(PanelController.shouldApplyCaretPlacement(
            initialFrame: initial, caretFrame: CGRect(x: 120, y: 110, width: 400, height: 500),
            initialMouse: mouse, currentMouse: mouse, interactionUnchanged: false))
    }
}
