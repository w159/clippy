import XCTest
@testable import Clippy

// Regression tests for the MCP port crash (H1): an out-of-range port typed into
// the Settings field used to reach `UInt16(port)` in isPortFree and trap, taking
// down the whole app. The fixes clamp the setting on write and guard the range
// in isPortFree.
@MainActor
final class McpServerControllerTests: XCTestCase {

    func testIsPortFreeRejectsOutOfRangePortsWithoutCrashing() {
        let controller = McpServerController.shared
        // Each of these would have trapped on UInt16(port) before the guard.
        XCTAssertFalse(controller.isPortFree(70000))
        XCTAssertFalse(controller.isPortFree(0))
        XCTAssertFalse(controller.isPortFree(-1))
        XCTAssertFalse(controller.isPortFree(Int(Int32.max)))
    }

    func testMcpPortClampsToValidRangeOnWrite() {
        let settings = AppSettings.shared
        let original = settings.mcpPort
        defer { settings.mcpPort = original }

        settings.mcpPort = 70000
        XCTAssertLessThanOrEqual(settings.mcpPort, 65535)
        XCTAssertGreaterThanOrEqual(settings.mcpPort, 1024)

        settings.mcpPort = 80
        XCTAssertGreaterThanOrEqual(settings.mcpPort, 1024)

        settings.mcpPort = 51764
        XCTAssertEqual(settings.mcpPort, 51764, "an in-range port must pass through unchanged")
    }
}
