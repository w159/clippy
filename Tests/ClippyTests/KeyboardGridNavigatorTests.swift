import XCTest
@testable import Clippy

final class KeyboardGridNavigatorTests: XCTestCase {
    func testSingleColumnUpDownAndLeftRightMoveByOne() {
        let nav = GridNavigator(columns: 1, count: 5)
        XCTAssertEqual(nav.index(from: 2, move: .down), 3)
        XCTAssertEqual(nav.index(from: 2, move: .up), 1)
        XCTAssertEqual(nav.index(from: 2, move: .right), 3)
        XCTAssertEqual(nav.index(from: 2, move: .left), 1)
    }

    func testEdgesClamp() {
        let nav = GridNavigator(columns: 3, count: 7)
        XCTAssertEqual(nav.index(from: 0, move: .up), 0)
        XCTAssertEqual(nav.index(from: 0, move: .left), 0)
        XCTAssertEqual(nav.index(from: 6, move: .down), 6)
        XCTAssertEqual(nav.index(from: 6, move: .right), 6)
    }

    func testDownMovesByOneRowForEveryColumnCount() {
        for columns in 1...6 {
            let nav = GridNavigator(columns: columns, count: 40)
            XCTAssertEqual(nav.index(from: 0, move: .down), columns)
            XCTAssertEqual(nav.index(from: columns, move: .up), 0)
        }
    }

    func testRaggedLastRowClampsToLastItem() {
        // 3 columns, 7 items: rows [0 1 2] [3 4 5] [6]
        let nav = GridNavigator(columns: 3, count: 7)
        XCTAssertEqual(nav.index(from: 5, move: .down), 6)
        XCTAssertEqual(nav.index(from: 4, move: .down), 6)
        XCTAssertEqual(nav.index(from: 3, move: .down), 6)
        XCTAssertEqual(nav.index(from: 6, move: .up), 3)
    }

    func testStickyColumnSurvivesShortRow() {
        let nav = GridNavigator(columns: 3, count: 7)
        let down = nav.target(from: 5, move: .down)
        XCTAssertEqual(down, GridNavigator.Target(index: 6, column: 2))
        let up = nav.target(from: down.index, move: .up, stickyColumn: down.column)
        XCTAssertEqual(up.index, 5)
    }

    func testLeftRightWrapAcrossRows() {
        let nav = GridNavigator(columns: 3, count: 7)
        XCTAssertEqual(nav.index(from: 2, move: .right), 3)
        XCTAssertEqual(nav.index(from: 3, move: .left), 2)
    }

    func testHomeEnd() {
        let nav = GridNavigator(columns: 4, count: 10)
        XCTAssertEqual(nav.index(from: 5, move: .home), 0)
        XCTAssertEqual(nav.index(from: 5, move: .end), 9)
    }

    func testPageMovesClampToFirstAndLastRow() {
        let nav = GridNavigator(columns: 2, count: 20, pageRows: 3)
        XCTAssertEqual(nav.index(from: 1, move: .pageDown), 7)
        XCTAssertEqual(nav.index(from: 7, move: .pageUp), 1)
        XCTAssertEqual(nav.index(from: 17, move: .pageDown), 19)
        XCTAssertEqual(nav.index(from: 3, move: .pageUp), 1)
    }

    func testSectionsStartNewRows() {
        // Sections of 2 and 3 with 2 columns: rows [0 1] [2 3] [4]
        let nav = GridNavigator(columns: 2, sectionLengths: [2, 3])
        XCTAssertEqual(nav.rowCount, 3)
        XCTAssertEqual(nav.index(from: 1, move: .down), 3)
        XCTAssertEqual(nav.index(from: 3, move: .down), 4)
        XCTAssertEqual(nav.index(from: 4, move: .up), 2)
        // Sections of 1 and 2 with 2 columns: rows [0] [1 2]
        let ragged = GridNavigator(columns: 2, sectionLengths: [1, 2])
        XCTAssertEqual(ragged.index(from: 0, move: .down), 1)
        XCTAssertEqual(ragged.index(from: 2, move: .up), 0)
    }

    func testEmptySectionsIgnoredAndEmptyGridSafe() {
        XCTAssertEqual(GridNavigator(columns: 2, sectionLengths: [0, 3, 0]).count, 3)
        let empty = GridNavigator(columns: 3, count: 0)
        XCTAssertEqual(empty.index(from: 4, move: .down), 0)
        XCTAssertNil(empty.location(of: 0))
    }

    func testInvalidColumnsAndOutOfRangeIndexClamp() {
        let nav = GridNavigator(columns: 0, count: 3)
        XCTAssertEqual(nav.columns, 1)
        XCTAssertEqual(nav.index(from: 99, move: .up), 1)
    }
}
