import XCTest
@testable import Clippy

/// Pure geometry tests for the panel's minimum size and saved-size clamping (PNL-03).
final class PanelLayoutTests: XCTestCase {
    /// One row of the minimum-size table.
    private struct SizeCase {
        let rail: CGFloat
        let card: CGFloat
        let gutters: CGFloat
        let rowHeight: CGFloat
        let expected: CGSize
    }

    /// Width is rail + divider + card + gutters; height is header + rows + footer.
    func testMinimumSizeTable() {
        let cases = [
            SizeCase(rail: 52, card: 180, gutters: 20, rowHeight: 32, expected: CGSize(width: 280, height: 240)),
            SizeCase(rail: 52, card: 240, gutters: 20, rowHeight: 40, expected: CGSize(width: 313, height: 264)),
            SizeCase(rail: 0, card: 300, gutters: 0, rowHeight: 10, expected: CGSize(width: 301, height: 174))
        ]
        for item in cases {
            let size = PanelLayout.minimumSize(
                railWidth: item.rail, minCardWidth: item.card, gutters: item.gutters, rowHeight: item.rowHeight)
            XCTAssertEqual(size, item.expected)
        }
    }

    /// Rail + divider + card + gutters below the floor yields exactly the floor.
    func testWidthFloorApplies() {
        let size = PanelLayout.minimumSize(railWidth: 52, minCardWidth: 180, gutters: 20, rowHeight: 32)
        XCTAssertEqual(size.width, PanelLayout.absoluteMinimumWidth)
    }

    /// Clamping a tiny saved size to the real minimum never goes under the floor.
    func testClampUpToStandardMinimumHonorsFloor() {
        let clamped = PanelLayout.clampUp(CGSize(width: 100, height: 100), toMinimum: PanelLayout.standardMinimumSize)
        XCTAssertEqual(clamped, PanelLayout.standardMinimumSize)
        XCTAssertGreaterThanOrEqual(clamped.width, PanelLayout.absoluteMinimumWidth)
    }

    /// Custom header and footer heights feed straight into the height.
    func testHeaderAndFooterHeightsAreUsed() {
        let size = PanelLayout.minimumSize(
            railWidth: 52, minCardWidth: 180, gutters: 20, rowHeight: 32, headerHeight: 50, footerHeight: 10)
        XCTAssertEqual(size.height, 50 + 96 + 10)
    }

    /// Growing any input never shrinks the result.
    func testMinimumSizeIsMonotonic() {
        let base = PanelLayout.minimumSize(railWidth: 52, minCardWidth: 180, gutters: 20, rowHeight: 32)
        let wider = PanelLayout.minimumSize(railWidth: 60, minCardWidth: 200, gutters: 30, rowHeight: 32)
        let taller = PanelLayout.minimumSize(railWidth: 52, minCardWidth: 180, gutters: 20, rowHeight: 40)
        XCTAssertGreaterThan(wider.width, base.width)
        XCTAssertEqual(wider.height, base.height)
        XCTAssertGreaterThan(taller.height, base.height)
        XCTAssertEqual(taller.width, base.width)
    }

    /// A saved size smaller than the minimum is clamped up per dimension.
    func testClampUpRaisesSmallSavedSize() {
        let minimum = CGSize(width: 300, height: 260)
        XCTAssertEqual(PanelLayout.clampUp(CGSize(width: 200, height: 500), toMinimum: minimum), CGSize(width: 300, height: 500))
        XCTAssertEqual(PanelLayout.clampUp(CGSize(width: 900, height: 100), toMinimum: minimum), CGSize(width: 900, height: 260))
    }

    /// Sizes already above the minimum pass through; garbage falls back to it.
    func testClampUpKeepsLargeAndRejectsInvalid() {
        let minimum = CGSize(width: 300, height: 260)
        let large = CGSize(width: 640, height: 480)
        XCTAssertEqual(PanelLayout.clampUp(large, toMinimum: minimum), large)
        XCTAssertEqual(PanelLayout.clampUp(CGSize(width: CGFloat.nan, height: -4), toMinimum: minimum), minimum)
    }

    /// The real-metrics minimum fits the rail plus one card.
    func testStandardMinimumFitsRailAndCard() {
        let size = PanelLayout.standardMinimumSize
        XCTAssertGreaterThanOrEqual(size.width, SidebarMetrics.railWidth + GridMetrics.minCardWidth)
    }
}
