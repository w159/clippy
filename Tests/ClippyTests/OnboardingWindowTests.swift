import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// The onboarding window must not keep a titlebar strip above its glass card.
@MainActor
final class OnboardingWindowTests: XCTestCase {
    func testCardFillsTheWindowWithNoFloatingTrafficLights() throws {
        let window = OnboardingWindowController.makeWindow(rootView: AnyView(Text("card")))
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<AnyView>)
        XCTAssertEqual(hosting.safeAreaRegions, [], "a titlebar safe area leaves an empty strip above the card")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(button)?.isHidden ?? true, true)
        }
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.styleMask.contains(.closable), "Cmd-W and Skip for now still close it")
    }
}
