import AppKit
import XCTest
@testable import Clippy

/// Dropped into the v2.4.0 checkout by the "Version comparison" job (with `openPanel` opened up to take a size).
/// Shoots 2.4.0's panel at its own default size, 920 x 560, so the comparison shows each version's panel as a user
/// first sees it. Same gate as the rest of the harness (`CLIPPY_UI_HARNESS=1`, enforced by `setUp`).
extension PanelHarnessTests {
    func testDefaultSizePanelScreenshots() throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try openPanel(appearance: appearance, size: NSSize(width: 920, height: 560))
            screenshot("50-panel-default-\(suffix)")
            window.orderOut(nil)
        }
    }
}
