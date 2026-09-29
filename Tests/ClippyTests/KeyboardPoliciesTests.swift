import XCTest
@testable import Clippy

final class KeyboardPoliciesTests: XCTestCase {
    func testEscapeStateMachine() {
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: true, query: "abc"), .clearSelection)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "abc"), .clearQuery)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: ""), .hidePanel)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "   "), .hidePanel)
    }

    func testQuickPasteIndexMapping() {
        XCTAssertEqual(QuickPasteMap.index(forDigit: "1", visibleCount: 5), 0)
        XCTAssertEqual(QuickPasteMap.index(forDigit: "5", visibleCount: 5), 4)
        XCTAssertNil(QuickPasteMap.index(forDigit: "6", visibleCount: 5))
        XCTAssertNil(QuickPasteMap.index(forDigit: "0", visibleCount: 5))
        XCTAssertNil(QuickPasteMap.index(forDigit: "a", visibleCount: 5))
        XCTAssertEqual(QuickPasteMap.index(forDigit: "9", visibleCount: 300), 8)
        XCTAssertNil(QuickPasteMap.index(forDigit: "1", visibleCount: 0))
    }

    func testSearchFieldOnlyWhereItWorks() {
        XCTAssertTrue(SearchFieldPolicy.showsSearchField(for: .history))
        XCTAssertTrue(SearchFieldPolicy.showsSearchField(for: .category(3)))
        XCTAssertTrue(SearchFieldPolicy.showsSearchField(for: .suggestions))
        for hidden: PanelSelection in [.assistant, .aiActions, .scripts, .onePassword] {
            XCTAssertFalse(SearchFieldPolicy.showsSearchField(for: hidden))
        }
    }

    func testContextMenuScope() {
        XCTAssertEqual(ContextMenuScope.resolve(clickedID: 1, multiSelection: [1, 2]), .batch)
        XCTAssertEqual(ContextMenuScope.resolve(clickedID: 3, multiSelection: [1, 2]), .single)
        XCTAssertEqual(ContextMenuScope.resolve(clickedID: 1, multiSelection: [1]), .single)
        XCTAssertEqual(ContextMenuScope.resolve(clickedID: nil, multiSelection: [1, 2]), .single)
    }

    func testSelectAllRouting() {
        XCTAssertEqual(SelectAllTarget.resolve(query: "x", searchHasFocus: true, fieldHasSelection: false), .text)
        XCTAssertEqual(SelectAllTarget.resolve(query: "", searchHasFocus: true, fieldHasSelection: true), .text)
        XCTAssertEqual(SelectAllTarget.resolve(query: "", searchHasFocus: true, fieldHasSelection: false), .clips)
        XCTAssertEqual(SelectAllTarget.resolve(query: "x", searchHasFocus: false, fieldHasSelection: false), .clips)
    }
}
