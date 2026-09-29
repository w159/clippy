import XCTest
@testable import Clippy

final class IntegrationAppRegistryTests: XCTestCase {
    private let feature: [SettingsPaneID] = [.preview, .pasteStack, .snippets, .semantic, .automation]

    func testFeaturePanesAreRegisteredAfterExistingPanesKeepOrder() {
        let all = SettingsPaneID.allCases
        let existing: [SettingsPaneID] = [.general, .appearance, .capture, .ai, .intelligence, .security, .data,
                                          .integrations, .scripts, .ocr, .editor, .about]
        XCTAssertEqual(all.filter(existing.contains), existing)
        for pane in feature { XCTAssertTrue(all.contains(pane)) }
        XCTAssertEqual(all.last, .about)
    }

    func testFeaturePanesHaveTitleIconAndSearchableEntry() {
        for pane in feature {
            XCTAssertFalse(pane.title.isEmpty)
            XCTAssertFalse(pane.icon.isEmpty)
            let entries = SettingsSearchCatalog.entries.filter { $0.pane == pane.rawValue }
            XCTAssertFalse(entries.isEmpty, pane.rawValue)
            XCTAssertFalse(entries.flatMap(\.keywords).isEmpty, pane.rawValue)
        }
    }

    func testSearchFindsFeaturePanesByKeyword() {
        let cases: [(String, SettingsPaneID)] = [("text expansion", .snippets), ("quick look", .preview),
                                                  ("paste next", .pasteStack), ("url scheme", .automation),
                                                  ("translate", .semantic)]
        for (query, pane) in cases {
            let hits = SettingsSearchIndex.search(query, in: SettingsSearchCatalog.entries)
            XCTAssertTrue(hits.contains { $0.entry.pane == pane.rawValue }, query)
        }
    }

    func testPaneIdsAndIconsAreUnique() {
        XCTAssertEqual(Set(SettingsPaneID.allCases.map(\.rawValue)).count, SettingsPaneID.allCases.count)
        XCTAssertEqual(Set(SettingsPaneID.allCases.map(\.icon)).count, SettingsPaneID.allCases.count)
    }

    func testPasteStackNextHotKeyActionIsUniqueAndUnbound() {
        let ids = HotKeyAction.allCases.map(\.carbonID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertNil(HotKeyAction.pasteStackNext.defaultChord)
        XCTAssertEqual(HotKeyAction.action(forCarbonID: HotKeyAction.pasteStackNext.carbonID), .pasteStackNext)
    }
}
