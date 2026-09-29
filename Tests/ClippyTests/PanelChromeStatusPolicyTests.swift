import XCTest
@testable import Clippy

final class PanelChromeStatusPolicyTests: XCTestCase {
    func testAutoDismissTimingPerSeverity() {
        XCTAssertEqual(PanelStatusPolicy.autoDismissSeconds(for: .success, hasAction: false), 3)
        XCTAssertEqual(PanelStatusPolicy.autoDismissSeconds(for: .info, hasAction: false), 4)
        XCTAssertEqual(PanelStatusPolicy.autoDismissSeconds(for: .warning, hasAction: false), 8)
        XCTAssertNil(PanelStatusPolicy.autoDismissSeconds(for: .failure, hasAction: false))
    }

    func testActionsKeepMessagesUntilDismissed() {
        for severity in [PanelStatusSeverity.info, .success, .warning, .failure] {
            XCTAssertNil(PanelStatusPolicy.autoDismissSeconds(for: severity, hasAction: true))
            XCTAssertTrue(PanelStatusPolicy.isPersistent(for: severity, hasAction: true))
        }
        XCTAssertFalse(PanelStatusPolicy.isPersistent(for: .success, hasAction: false))
        XCTAssertTrue(PanelStatusPolicy.isPersistent(for: .failure, hasAction: false))
    }

    func testRepeatedMessagesAreDistinctStatusItems() {
        let first = PanelStatusItem(message: "Saved", severity: .success, actionTitle: nil, isPersistent: false)
        let replacement = PanelStatusItem(message: "Saved", severity: .success, actionTitle: nil, isPersistent: false)
        XCTAssertNotEqual(first, replacement)
        XCTAssertEqual(first, first)
    }

    func testSeverityMapsToBannerSeverity() {
        XCTAssertEqual(PanelStatusSeverity.info.banner, .neutral)
        XCTAssertEqual(PanelStatusSeverity.success.banner, .success)
        XCTAssertEqual(PanelStatusSeverity.warning.banner, .warning)
        XCTAssertEqual(PanelStatusSeverity.failure.banner, .danger)
    }
}
