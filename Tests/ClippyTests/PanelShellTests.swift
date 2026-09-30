import XCTest
@testable import Clippy

final class PanelShellTests: XCTestCase {
    private struct Cmd: PaletteCommand {
        let id: String
        let title: String
        var subtitle: String?
        var keywords: [String] = []
        var isEnabled = true
        var symbol: String { "circle" }
        func perform() {}
    }

    private func titles(_ query: String, _ commands: [Cmd]) -> [String] {
        PaletteRanker.rank(commands, query: query).map(\.title)
    }

    // MARK: - Palette ranking

    func testEmptyQueryKeepsOrderAndDropsDisabled() {
        let list = [Cmd(id: "a", title: "Paste"), Cmd(id: "b", title: "Pin", isEnabled: false), Cmd(id: "c", title: "Delete")]
        XCTAssertEqual(titles("  ", list), ["Paste", "Delete"])
    }

    func testPrefixBeatsSubstringBeatsSubsequence() {
        let list = [Cmd(id: "1", title: "Toggle sidebar"), Cmd(id: "2", title: "Paste as plain text"), Cmd(id: "3", title: "Pin")]
        XCTAssertEqual(titles("pin", list).first, "Pin")
        XCTAssertEqual(titles("pl", list).first, "Paste as plain text")
    }

    func testSubsequenceMatchesAndNonMatchIsDropped() {
        let list = [Cmd(id: "1", title: "Open Settings"), Cmd(id: "2", title: "Delete")]
        XCTAssertEqual(titles("ost", list), ["Open Settings"])
        XCTAssertTrue(titles("zzz", list).isEmpty)
    }

    func testEveryTokenMustMatchAndKeywordsCount() {
        let list = [Cmd(id: "1", title: "Extract text", keywords: ["ocr"]), Cmd(id: "2", title: "Paste as plain text")]
        XCTAssertEqual(titles("ocr", list), ["Extract text"])
        XCTAssertEqual(titles("plain text", list), ["Paste as plain text"])
        XCTAssertTrue(titles("ocr plain", list).isEmpty)
    }

    func testTitleOutranksSubtitleAndTiesKeepOrder() {
        let list = [Cmd(id: "1", title: "Zed", subtitle: "delete things"), Cmd(id: "2", title: "Delete")]
        XCTAssertEqual(titles("delete", list), ["Delete", "Zed"])
        let ties = [Cmd(id: "1", title: "Alpha one"), Cmd(id: "2", title: "Alpha two")]
        XCTAssertEqual(titles("alpha", ties).count, 2)
    }

    func testDiacriticsAndCaseAreFolded() {
        XCTAssertEqual(titles("CAFE", [Cmd(id: "1", title: "Café")]), ["Café"])
    }

    // MARK: - Filter chips <-> query string

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private var now: Date { calendar.date(from: DateComponents(year: 2025, month: 6, day: 15, hour: 12))! }

    private var editor: SearchChipEditor {
        SearchChipEditor(now: now, calendar: calendar,
                         categoryID: { $0 == "Work" ? 7 : nil }, categoryName: { $0 == 7 ? "Work" : nil },
                         appNames: ["Visual Studio Code"])
    }

    func testKindToggleRoundTripKeepsFreeText() {
        let added = editor.toggling(kind: .image, in: "invoice -draft")
        XCTAssertEqual(added, "invoice -draft kind:image")
        XCTAssertEqual(editor.filter(of: added).kinds, [.image])
        XCTAssertEqual(editor.toggling(kind: .image, in: added), "invoice -draft")
    }

    func testAppAndCategoryChipsQuoteAndRoundTrip() {
        let query = editor.toggling(categoryID: 7, in: editor.toggling(app: "Visual Studio Code", in: "x"))
        XCTAssertEqual(query, "x app:\"Visual Studio Code\" in:Work")
        let filter = editor.filter(of: query)
        XCTAssertEqual(filter.apps, ["Visual Studio Code"])
        XCTAssertEqual(filter.categoryIDs, [7])
        XCTAssertEqual(editor.toggling(app: "visual studio code", in: query), "x in:Work")
    }

    func testDatePresetSetDetectAndClear() {
        let today = editor.setting(date: .today, in: "note")
        XCTAssertEqual(today, "note after:2025-06-15")
        XCTAssertEqual(SearchDatePreset.matching(editor.filter(of: today), now: now, calendar: calendar), .today)
        XCTAssertEqual(editor.setting(date: .today, in: today), "note")
        let yesterday = editor.setting(date: .yesterday, in: "note")
        XCTAssertEqual(yesterday, "note on:2025-06-14")
        XCTAssertEqual(SearchDatePreset.matching(editor.filter(of: yesterday), now: now, calendar: calendar), .yesterday)
    }

    func testClearingFiltersKeepsFreeTextOnly() {
        XCTAssertEqual(editor.clearingFilters(in: "hello kind:image app:chrome after:2025-01-01"), "hello")
    }

    // MARK: - Panel layout

    func testMinimumSizeSumsRailCardAndGutters() {
        let size = PanelLayout.minimumSize(railWidth: 52, minCardWidth: 240, gutters: 20, rowHeight: 32,
                                           headerHeight: 100, footerHeight: 30, visibleRows: 3)
        // 52 + 1 (divider) + 240 + 20 = 313, above the 280 floor.
        XCTAssertEqual(size.width, 313)
        XCTAssertEqual(size.height, 226)
    }

    func testMinimumSizeNeverBelowAbsoluteWidthAndSanitisesInput() {
        let narrow = PanelLayout.minimumSize(railWidth: 10, minCardWidth: 10, gutters: 0, rowHeight: 10)
        XCTAssertEqual(narrow.width, PanelLayout.absoluteMinimumWidth)
        let bad = PanelLayout.minimumSize(railWidth: -5, minCardWidth: .nan, gutters: .infinity, rowHeight: -1, visibleRows: 0)
        XCTAssertEqual(bad.width, PanelLayout.absoluteMinimumWidth)
        XCTAssertEqual(bad.height, PanelLayout.headerHeight + PanelLayout.footerHeight)
    }

    func testStandardMinimumSizeFitsRailAndOneCard() {
        let size = PanelLayout.standardMinimumSize
        XCTAssertGreaterThanOrEqual(size.width, SidebarMetrics.railWidth + GridMetrics.minCardWidth)
    }

    // MARK: - Escape stays two-stage

    func testEscapeStagesUnchanged() {
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: true, query: "a"), .clearSelection)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "a"), .clearQuery)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: " "), .hidePanel)
    }
}

final class PaletteLayoutTests: XCTestCase {
    private func cmd(_ id: String, _ section: PaletteSection) -> ClosurePaletteCommand {
        ClosurePaletteCommand(id: id, title: id, symbol: "circle", section: section, perform: {})
    }

    private var sample: [any PaletteCommand] {
        [cmd("a", .actions), cmd("b", .settings), cmd("c", .navigate), cmd("d", .actions)]
    }

    func testEmptyQueryGroupsRecentFirstThenSectionsWithoutDuplicates() {
        let layout = PaletteLayout.build(sample, query: "", recents: ["c", "zz", "c"])
        XCTAssertEqual(layout.groups.map(\.title), ["Recent", "Actions", "Settings"])
        XCTAssertEqual(layout.flat.map(\.id), ["c", "a", "d", "b"])
        XCTAssertEqual(layout.sectionStarts, [0, 1, 3])
    }

    func testQueryIsSingleHeaderlessRankedList() {
        let layout = PaletteLayout.build(sample, query: "a", recents: ["c"])
        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertNil(layout.groups[0].title)
        XCTAssertTrue(PaletteLayout.build(sample, query: "nomatch", recents: []).groups.isEmpty)
    }

    func testTabJumpsBetweenSectionsAndWraps() {
        let starts = [0, 1, 3]
        XCTAssertEqual(PaletteLayout.jump(from: 0, sectionStarts: starts, forward: true), 1)
        XCTAssertEqual(PaletteLayout.jump(from: 2, sectionStarts: starts, forward: true), 3)
        XCTAssertEqual(PaletteLayout.jump(from: 3, sectionStarts: starts, forward: true), 0)
        XCTAssertEqual(PaletteLayout.jump(from: 2, sectionStarts: starts, forward: false), 1)
        XCTAssertEqual(PaletteLayout.jump(from: 0, sectionStarts: starts, forward: false), 3)
    }

    func testKeyCapsSplitGlyphsAndPlusForms() {
        XCTAssertEqual(PaletteLayout.keyCaps(for: "\u{21E7}\u{21A9}"), ["\u{21E7}", "\u{21A9}"])
        XCTAssertEqual(PaletteLayout.keyCaps(for: "Cmd+P"), ["Cmd", "P"])
        XCTAssertEqual(PaletteLayout.keyCaps(for: "esc"), ["e", "s", "c"])
    }
}
