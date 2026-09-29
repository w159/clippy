import XCTest
@testable import Clippy

final class PanelChromeFilterChipTests: XCTestCase {
    private var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }()
    private lazy var now: Date = calendar.date(from: DateComponents(year: 2025, month: 3, day: 15, hour: 12))!
    private let categoryIDs = ["work": Int64(7), "home": Int64(9)]

    private var editor: SearchChipEditor {
        SearchChipEditor(
            now: now, calendar: calendar,
            categoryID: { [categoryIDs] name in categoryIDs[name.lowercased()] },
            categoryName: { id in id == 7 ? "Work" : (id == 9 ? "Home" : nil) },
            appNames: ["Google Chrome", "Safari"]
        )
    }

    func testTypedKindShowsAsChipFilter() {
        XCTAssertEqual(editor.filter(of: "kind:image").kinds, [.image])
        XCTAssertEqual(editor.filter(of: "#image invoice").kinds, [.image])
    }

    func testKindToggleRoundTripKeepsFreeText() {
        let added = editor.toggling(kind: .image, in: "invoice")
        XCTAssertEqual(added, "invoice kind:image")
        XCTAssertEqual(editor.filter(of: added).kinds, [.image])
        XCTAssertEqual(editor.toggling(kind: .image, in: added), "invoice")
    }


    func testAppNamesResolveToDisplayCasingAndUnknownKeepsTypedCasing() {
        XCTAssertEqual(editor.filter(of: "app:chrome").apps, ["chrome"])
        XCTAssertEqual(editor.filter(of: "app:safari").apps, ["Safari"])
        XCTAssertEqual(editor.filter(of: "app:\"google chrome\"").apps, ["Google Chrome"])
        XCTAssertEqual(editor.filter(of: "app:FooBar").apps, ["FooBar"])
        XCTAssertEqual(editor.filter(of: "-app:Foo").apps, [])
    }

    func testCategoryToggleRoundTrip() {
        let added = editor.toggling(categoryID: 7, in: "")
        XCTAssertEqual(added, "in:Work")
        XCTAssertEqual(editor.filter(of: added).categoryIDs, [7])
        XCTAssertEqual(editor.toggling(categoryID: 7, in: added), "")
    }

    func testDatePresetsRoundTripAndToggleOff() {
        let today = editor.setting(date: .today, in: "")
        XCTAssertEqual(today, "after:2025-03-15")
        XCTAssertEqual(SearchDatePreset.matching(editor.filter(of: today), now: now, calendar: calendar), .today)
        XCTAssertEqual(editor.setting(date: .today, in: today), "")

        let yesterday = editor.setting(date: .yesterday, in: "")
        XCTAssertEqual(yesterday, "on:2025-03-14")
        XCTAssertEqual(SearchDatePreset.matching(editor.filter(of: yesterday), now: now, calendar: calendar), .yesterday)

        XCTAssertEqual(editor.setting(date: .week, in: ""), "after:2025-03-09")
    }

    func testCustomDateMatchesNoPreset() {
        let filter = editor.filter(of: "after:2024-01-01")
        XCTAssertNil(SearchDatePreset.matching(filter, now: now, calendar: calendar))
    }

    func testNegationsAndSizesSurviveChipEdits() {
        let result = editor.toggling(kind: .image, in: "-draft -app:chrome size:>1mb invoice")
        XCTAssertTrue(result.contains("-draft"))
        XCTAssertTrue(result.contains("-app:chrome"))
        XCTAssertTrue(result.contains("size:>1mb"))
        XCTAssertTrue(result.contains("kind:image"))
        XCTAssertEqual(editor.filter(of: result).kinds, [.image])
    }

    func testMultipleChipsAndClearAll() {
        var query = "invoice"
        query = editor.toggling(kind: .image, in: query)
        query = editor.toggling(app: "Safari", in: query)
        query = editor.toggling(categoryID: 9, in: query)
        query = editor.setting(date: .today, in: query)
        XCTAssertEqual(query, "invoice kind:image app:Safari in:Home after:2025-03-15")
        let filter = editor.filter(of: query)
        XCTAssertEqual(filter.kinds, [.image])
        XCTAssertEqual(filter.apps, ["Safari"])
        XCTAssertEqual(filter.categoryIDs, [9])
        XCTAssertFalse(filter.isEmpty)
        XCTAssertEqual(editor.clearingFilters(in: query), "invoice")
    }

    func testSearchWarningsReportOnlyProblems() {
        XCTAssertTrue(SearchWarnings.messages(for: "").isEmpty)
        XCTAssertTrue(SearchWarnings.messages(for: "invoice kind:image").isEmpty)
        XCTAssertEqual(SearchWarnings.messages(for: "kind:bogus"), ["Unknown kind in kind:bogus"])
    }
}
