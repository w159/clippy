import XCTest
@testable import Clippy

/// Seeded fault: a pill that ignores the seen list stays on forever, as it did.
final class SettingsSeenPanesTests: XCTestCase {
    func testNewPillShowsUntilThePaneIsOpened() {
        XCTAssertTrue(SettingsSeenPanes.showsNewPill(.snippets, seen: ""))
        let seen = SettingsSeenPanes.marking(.snippets, in: "")
        XCTAssertFalse(SettingsSeenPanes.showsNewPill(.snippets, seen: seen))
        XCTAssertTrue(SettingsSeenPanes.showsNewPill(.automation, seen: seen), "other panes keep their pill")
        XCTAssertEqual(SettingsSeenPanes.marking(.snippets, in: seen), seen, "marking twice changes nothing")
    }

    func testPanesThatAreNotNewNeverShowThePill() {
        XCTAssertFalse(SettingsSeenPanes.showsNewPill(.general, seen: ""))
        XCTAssertEqual(SettingsSeenPanes.marking(.general, in: "snippets"), "snippets")
    }
}
