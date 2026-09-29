import XCTest
@testable import Clippy

final class CommandPaletteRankerTests: XCTestCase {
    private func command(_ title: String, keywords: [String] = [], enabled: Bool = true) -> ClosurePaletteCommand {
        ClosurePaletteCommand(id: title, title: title, symbol: "circle", keywords: keywords, isEnabled: enabled, perform: {})
    }

    private func titles(_ commands: [any PaletteCommand]) -> [String] { commands.map(\.title) }

    func testPrefixBeatsWordStartBeatsSubstringBeatsSubsequence() {
        let input = [command("Sort Elements"), command("Reset"), command("Open Settings"), command("Settings")]
        let ranked = PaletteRanker.rank(input, query: "set")
        XCTAssertEqual(titles(ranked), ["Settings", "Open Settings", "Reset", "Sort Elements"])
    }

    func testTitleBeatsKeywordAndKeywordMatches() {
        let input = [command("Other", keywords: ["pin"]), command("Pin")]
        XCTAssertEqual(titles(PaletteRanker.rank(input, query: "pin")), ["Pin", "Other"])
        let layout = [command("Change density", keywords: ["layout"]), command("Delete")]
        XCTAssertEqual(titles(PaletteRanker.rank(layout, query: "layout")), ["Change density"])
    }

    func testTiesKeepOriginalOrder() {
        let input = [command("Alpha one"), command("Alpha two")]
        XCTAssertEqual(titles(PaletteRanker.rank(input, query: "alpha")), ["Alpha one", "Alpha two"])
    }

    func testEmptyQueryReturnsEnabledInOrderAndHidesDisabled() {
        let input = [command("Zed"), command("Hidden", enabled: false), command("Alpha")]
        XCTAssertEqual(titles(PaletteRanker.rank(input, query: "  ")), ["Zed", "Alpha"])
        XCTAssertTrue(PaletteRanker.rank(input, query: "hidden").isEmpty)
    }

    func testEveryTokenMustMatchAndCaseAndDiacriticsFold() {
        let input = [command("Paste as plain text"), command("Paste")]
        XCTAssertEqual(titles(PaletteRanker.rank(input, query: "paste plain")), ["Paste as plain text"])
        XCTAssertEqual(titles(PaletteRanker.rank([command("Caf\u{00E9} menu")], query: "CAFE")), ["Caf\u{00E9} menu"])
    }

    func testBuiltInCommandsFollowSelectionState() {
        func context(clip: Bool, query: Bool) -> PanelCommandContext {
            PanelCommandContext(
                hasSelectedClip: clip, hasQuery: query, canExtractText: false, canFindSimilar: true, isPinned: true,
                paste: {}, pastePlain: {}, togglePin: {}, deleteSelection: {}, findSimilar: {}, openSettings: {},
                toggleSidebar: {}, currentDensity: .compact, setDensity: { _ in }, suggestionsEnabled: false,
                toggleSuggestions: {}, clearSearch: {}, extractText: {}, newCategory: {})
        }
        let none = Set(BuiltInCommands.make(context(clip: false, query: false)).filter(\.isEnabled).map(\.id))
        XCTAssertEqual(none, ["sidebar", "density-comfortable", "density-cards", "suggestions", "settings"])
        let some = BuiltInCommands.make(context(clip: true, query: true)).filter(\.isEnabled)
        XCTAssertTrue(some.contains { $0.id == "pin" && $0.title == "Unpin" })
        XCTAssertTrue(some.contains { $0.id == "clear-search" })
        XCTAssertFalse(some.contains { $0.id == "extract-text" })
    }

    func testEmptyQueryPromotesRecentsInRecencyOrderAndIgnoresUnknownOrDisabled() {
        let input = [command("Alpha"), command("Beta"), command("Gone", enabled: false), command("Gamma")]
        let ranked = PaletteRanker.rank(input, query: " ", recents: ["Gamma", "Missing", "Gone", "Beta", "Gamma"])
        XCTAssertEqual(titles(ranked), ["Gamma", "Beta", "Alpha"])
    }

    func testRecentsDoNotAffectNonEmptyQuery() {
        let input = [command("Alpha one"), command("Alpha two")]
        XCTAssertEqual(titles(PaletteRanker.rank(input, query: "alpha", recents: ["Alpha two"])), ["Alpha one", "Alpha two"])
    }

    func testPushRecentMovesToFrontDedupesAndCaps() {
        XCTAssertEqual(PaletteRanker.pushRecent("c", into: ["a", "b", "c"], limit: 3), ["c", "a", "b"])
        XCTAssertEqual(PaletteRanker.pushRecent("d", into: ["a", "b", "c"], limit: 3), ["d", "a", "b"])
    }
}
