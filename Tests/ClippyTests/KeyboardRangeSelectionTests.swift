import XCTest
@testable import Clippy

final class KeyboardRangeSelectionTests: XCTestCase {
    private let order: [Int64] = [10, 20, 30, 40, 50, 60]

    func testShiftExtendGrowsThenShrinksFromAnchor() {
        var model = RangeSelectionModel()
        model.reset(to: 30)
        model.extend(to: 40, order: order)
        model.extend(to: 50, order: order)
        XCTAssertEqual(model.selected, [30, 40, 50])
        model.extend(to: 40, order: order)
        XCTAssertEqual(model.selected, [30, 40])
        model.extend(to: 30, order: order)
        XCTAssertEqual(model.selected, [30])
        XCTAssertTrue(model.published.isEmpty)
        XCTAssertEqual(model.cursor, 30)
    }

    func testExtendCrossesAnchor() {
        var model = RangeSelectionModel()
        model.reset(to: 30)
        model.extend(to: 50, order: order)
        model.extend(to: 10, order: order)
        XCTAssertEqual(model.selected, [10, 20, 30])
        XCTAssertEqual(model.anchor, 30)
    }

    func testShiftClickShrinksToo() {
        var model = RangeSelectionModel()
        model.reset(to: 10)
        model.extend(to: 60, order: order)
        model.extend(to: 30, order: order)
        XCTAssertEqual(model.selected, [10, 20, 30])
    }

    func testCommandToggleKeepsOthersAndShiftKeepsCommitted() {
        var model = RangeSelectionModel()
        model.reset(to: 10)
        model.toggle(30)
        XCTAssertEqual(model.selected, [10, 30])
        model.extend(to: 50, order: order)
        XCTAssertEqual(model.selected, [10, 30, 40, 50])
        model.extend(to: 30, order: order)
        XCTAssertEqual(model.selected, [10, 30])
        model.toggle(10)
        XCTAssertEqual(model.selected, [30])
        XCTAssertFalse(model.isTrivial, "a lone non-cursor selection stays actionable")
    }

    func testSelectAllAndCollapse() {
        var model = RangeSelectionModel()
        model.reset(to: 20)
        model.selectAll(order: order)
        XCTAssertEqual(model.selected, Set(order))
        XCTAssertEqual(model.cursor, 20)
        model.collapseToCursor()
        XCTAssertEqual(model.selected, [20])
        XCTAssertTrue(model.published.isEmpty)
    }

    func testPruneDropsMissingClipsAndEndpoints() {
        var model = RangeSelectionModel()
        model.reset(to: 10)
        model.extend(to: 30, order: order)
        model.prune(keeping: [20, 30])
        XCTAssertEqual(model.selected, [20, 30])
        XCTAssertNil(model.anchor)
        XCTAssertEqual(model.cursor, 30)
    }

    func testExtendWithMissingAnchorFallsBackToCursor() {
        var model = RangeSelectionModel()
        model.reset(to: 20)
        model.prune(keeping: [20, 30, 40])
        model.extend(to: 40, order: [20, 30, 40])
        XCTAssertEqual(model.selected, [20, 30, 40])
    }

    func testAdoptResyncsAfterExternalChange() {
        var model = RangeSelectionModel()
        model.reset(to: 10)
        model.extend(to: 30, order: order)
        model.adopt(published: [], cursor: 30)
        XCTAssertEqual(model.selected, [30])
        model.adopt(published: [20, 40], cursor: 40)
        XCTAssertEqual(model.published, [20, 40])
        model.extend(to: 50, order: order)
        XCTAssertEqual(model.selected, [20, 40, 50])
    }

    func testExtendToUnknownIDIsNoOp() {
        var model = RangeSelectionModel()
        model.reset(to: 10)
        model.extend(to: 999, order: order)
        XCTAssertEqual(model.selected, [10])
    }
}
