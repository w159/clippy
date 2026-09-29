import XCTest
@testable import Clippy

final class PanelGeometryTests: XCTestCase {

    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)

    func testPanelInsideScreenIsUnchanged() {
        let rect = NSRect(x: 100, y: 100, width: 640, height: 480)
        XCTAssertEqual(PanelGeometry.clamp(rect, within: screen), rect)
    }

    func testOriginOffScreenIsSlidBackInsideWithMargin() {
        let clamped = PanelGeometry.clamp(NSRect(x: -500, y: 5_000, width: 640, height: 480), within: screen)
        XCTAssertEqual(clamped.minX, screen.minX + PanelGeometry.margin)
        XCTAssertEqual(clamped.maxY, screen.maxY - PanelGeometry.margin)
    }

    func testPanelTallerThanScreenIsShrunkAndKeepsTopEdgeVisible() {
        let clamped = PanelGeometry.clamp(NSRect(x: 50, y: 0, width: 640, height: 2_000), within: screen)
        XCTAssertEqual(clamped.height, screen.height - 2 * PanelGeometry.margin)
        XCTAssertEqual(clamped.minY, screen.minY + PanelGeometry.margin)
        XCTAssertEqual(clamped.maxY, screen.maxY - PanelGeometry.margin)
    }

    func testPanelWiderThanScreenIsShrunk() {
        let clamped = PanelGeometry.clamp(NSRect(x: 900, y: 100, width: 5_000, height: 300), within: screen)
        XCTAssertEqual(clamped.width, screen.width - 2 * PanelGeometry.margin)
        XCTAssertEqual(clamped.minX, PanelGeometry.margin)
    }

    func testDisplayMemoryRoundTripsAndPrunesDisconnectedDisplays() {
        let name = "clippy-display-memory-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        let memory = PanelDisplayMemory(defaults: suite)
        memory.save(origin: CGPoint(x: 10, y: 20), for: 1)
        memory.save(origin: CGPoint(x: 30, y: 40), for: 2)
        XCTAssertEqual(memory.origin(for: 1), CGPoint(x: 10, y: 20))
        memory.prune(keeping: [2])
        XCTAssertNil(memory.origin(for: 1))
        XCTAssertEqual(memory.origin(for: 2), CGPoint(x: 30, y: 40))
    }
}
