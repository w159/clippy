import XCTest
@testable import Clippy

final class PanelDisclosureTests: XCTestCase {
    func testFilterRowRules() {
        XCTAssertFalse(PanelDisclosure.showsFilterRow(query: "", hasActiveFilters: false, userToggled: false))
        XCTAssertFalse(PanelDisclosure.showsFilterRow(query: "  ", hasActiveFilters: false, userToggled: false))
        XCTAssertTrue(PanelDisclosure.showsFilterRow(query: "a", hasActiveFilters: false, userToggled: false))
        XCTAssertTrue(PanelDisclosure.showsFilterRow(query: "", hasActiveFilters: true, userToggled: false))
        XCTAssertTrue(PanelDisclosure.showsFilterRow(query: "", hasActiveFilters: false, userToggled: true))
    }

    func testOperatorHintsOnlyWhenFocusedAndEmpty() {
        XCTAssertTrue(PanelDisclosure.showsOperatorHints(focused: true, query: ""))
        XCTAssertFalse(PanelDisclosure.showsOperatorHints(focused: false, query: ""))
        XCTAssertFalse(PanelDisclosure.showsOperatorHints(focused: true, query: "x"))
    }

    func testFooterHintsAreCappedAndContextual() {
        let wide = PanelDisclosure.footerHints(selectedCount: 1, hasClips: true, plainByDefault: false, isPinnedPanel: false, width: 720)
        XCTAssertEqual(wide.count, 4)
        XCTAssertEqual(wide[0].label, "paste")
        let narrow = PanelDisclosure.footerHints(selectedCount: 1, hasClips: true, plainByDefault: true, isPinnedPanel: false, width: 360)
        XCTAssertEqual(narrow.count, 3)
        XCTAssertEqual(narrow[0].label, "paste plain")
        let multi = PanelDisclosure.footerHints(selectedCount: 3, hasClips: true, plainByDefault: false, isPinnedPanel: false, width: 720)
        XCTAssertTrue(multi.contains { $0.label == "delete" })
        let empty = PanelDisclosure.footerHints(selectedCount: 0, hasClips: false, plainByDefault: false, isPinnedPanel: true, width: 720)
        XCTAssertEqual(empty.last?.label, "pinned")
    }

    func testSidebarExpansion() {
        XCTAssertEqual(PanelDisclosure.decode(nil), [.library, .categories])
        XCTAssertEqual(PanelDisclosure.decode(""), [])
        XCTAssertEqual(PanelDisclosure.decode("tools,bogus"), [.tools])
        let round: Set<PanelDisclosure.SidebarSection> = [.tools, .library]
        XCTAssertEqual(PanelDisclosure.decode(PanelDisclosure.encode(round)), round)
        XCTAssertTrue(PanelDisclosure.isExpanded(.tools, stored: [], containsSelection: true))
        XCTAssertFalse(PanelDisclosure.isExpanded(.tools, stored: [], containsSelection: false))
    }
}
