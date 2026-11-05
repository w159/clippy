import XCTest
@testable import Clippy

/// The shell model is the single writer of the seen-panes key; every route that shows a
/// pane (launch request, sidebar, search jump) must clear its NEW pill, also after relaunch.
@MainActor
final class SettingsSeenPanesPersistenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "seen-panes-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeModel(requested: String = "") -> SettingsShellModel {
        SettingsShellModel(seenDefaults: defaults, requestedSection: requested)
    }

    private var stored: String { defaults.string(forKey: SettingsSeenPanes.defaultsKey) ?? "" }

    func testInitMarksTheRequestedPane() {
        _ = makeModel(requested: "snippets")
        XCTAssertFalse(SettingsSeenPanes.showsNewPill(.snippets, seen: stored))
        XCTAssertTrue(SettingsSeenPanes.showsNewPill(.automation, seen: stored))
    }

    func testJumpMarksThePaneFromSearch() {
        let model = makeModel()
        XCTAssertEqual(stored, "")
        let entry = SettingsSearchEntry(id: "p", pane: SettingsPaneID.preview.rawValue, title: "Preview")
        model.jump(to: SettingsSearchHit(entry: entry, score: 1))
        XCTAssertEqual(model.selection, .preview)
        XCTAssertFalse(SettingsSeenPanes.showsNewPill(.preview, seen: stored))
    }

    func testSeenPanesSurviveRelaunch() {
        let first = makeModel()
        first.selection = .pasteStack
        let second = makeModel()
        XCTAssertEqual(second.selection, .general)
        XCTAssertFalse(SettingsSeenPanes.showsNewPill(.pasteStack, seen: stored))
        XCTAssertTrue(SettingsSeenPanes.showsNewPill(.automation, seen: stored))
    }
}
