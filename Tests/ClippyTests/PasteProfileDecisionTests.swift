import XCTest

@testable import Clippy

/// FEAT-19: plain/rich decision across every paste route.
final class PasteProfileDecisionTests: XCTestCase {
    private let terminal = "com.apple.Terminal"
    private let notes = "com.example.notes"
    private var saved: UserDefaults!

    override func setUp() {
        saved = CapturePreferences.defaults
        CapturePreferences.defaults = UserDefaults(suiteName: "profile-tests-\(UUID().uuidString)")!
    }

    override func tearDown() { CapturePreferences.defaults = saved }

    func testTerminalsGetPlainOnEveryTextRoute() {
        for route in PasteRoute.allCases where route != .file {
            XCTAssertTrue(PasteProfileDecision.shouldPastePlain(route: route, bundleID: terminal, callerAsksPlain: false), "\(route)")
        }
    }

    func testAutomaticAppsFollowCallerExceptCombinedAndFile() {
        for route in [PasteRoute.paste, .pasteStack, .multiPasteSequence, .statusItem] {
            XCTAssertFalse(PasteProfileDecision.shouldPastePlain(route: route, bundleID: notes, callerAsksPlain: false))
            XCTAssertTrue(PasteProfileDecision.shouldPastePlain(route: route, bundleID: notes, callerAsksPlain: true))
        }
        XCTAssertTrue(PasteProfileDecision.shouldPastePlain(route: .pastePlainHotkey, bundleID: notes, callerAsksPlain: false))
        XCTAssertTrue(PasteProfileDecision.shouldPastePlain(route: .multiPasteCombined, bundleID: notes, callerAsksPlain: false))
        XCTAssertFalse(PasteProfileDecision.shouldPastePlain(route: .file, bundleID: terminal, callerAsksPlain: true))
    }

    func testRichOverrideWinsExceptForExplicitPlainHotkey() {
        PasteProfiles.setMode(.rich, forBundleID: terminal)
        XCTAssertFalse(PasteProfileDecision.shouldPastePlain(route: .paste, bundleID: terminal, callerAsksPlain: true))
        XCTAssertFalse(PasteProfileDecision.shouldPastePlain(route: .pasteStack, bundleID: terminal, callerAsksPlain: true))
        XCTAssertTrue(PasteProfileDecision.shouldPastePlain(route: .pastePlainHotkey, bundleID: terminal, callerAsksPlain: true))
    }
}
