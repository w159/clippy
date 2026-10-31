import XCTest
@testable import Clippy

/// Search behavior above the database: which clips History lists while
/// searching, where the cursor lands on new results, and Return mid-typing.
@MainActor
final class SearchResultPolicyTests: XCTestCase {
    private func clip(_ id: Int64, _ text: String = "x") -> Clip {
        var clip = makeTextClip(text)
        clip.id = id
        return clip
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if condition() { timer.invalidate(); done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
        timer.invalidate()
    }

    // MARK: - History pane

    func testHistoryBrowsingHidesFiledClipsButSearchingFindsThem() {
        let clips = [clip(1), clip(2), clip(3)]
        let filed: (Clip) -> Bool = { $0.id == 2 }
        XCTAssertEqual(HistoryPanePolicy.visible(clips, query: "", isFiled: filed).compactMap(\.id), [1, 3])
        XCTAssertEqual(HistoryPanePolicy.visible(clips, query: "  \n", isFiled: filed).compactMap(\.id), [1, 3])
        XCTAssertEqual(HistoryPanePolicy.visible(clips, query: "x", isFiled: filed).compactMap(\.id), [1, 2, 3])
    }

    func testFiledClipIsFoundFromHistorySearchEndToEnd() throws {
        let db = try makeTestDatabase(self)
        var filed = makeTextClip("quarterly invoice for Acme")
        try db.saveCapturedClip(&filed, cap: 100)
        var loose = makeTextClip("lunch order")
        try db.saveCapturedClip(&loose, cap: 100)
        let filedID = try XCTUnwrap(try db.allClips().first { $0.contentText.hasPrefix("quarterly") }?.id)
        let category = try db.createCategory(named: "Work", colorHex: "#FF0000", iconKind: .symbol, iconValue: "star")
        try db.setClip(filedID, inCategory: try XCTUnwrap(category.id), true)

        let store = ClipStore(database: db)
        waitFor("filed membership loaded") { store.isPinned(filed.withID(filedID)) && store.clips.count == 2 }
        XCTAssertEqual(HistoryPanePolicy.visible(store.clips, query: store.query, isFiled: { store.isPinned($0) })
            .map(\.contentText), ["lunch order"])

        store.query = "invoice"
        waitFor("search landed") { !store.hasPendingSearch }
        XCTAssertEqual(HistoryPanePolicy.visible(store.clips, query: store.query, isFiled: { store.isPinned($0) })
            .map(\.contentText), ["quarterly invoice for Acme"])
    }

    // MARK: - One meaning of a search everywhere

    /// History (database) and a category pane (in memory) must agree on what a
    /// query matches; they used to differ (word prefixes versus fragments).
    func testHistoryAndCategoryPaneMatchTheSameClips() throws {
        let db = try makeTestDatabase(self)
        let texts = ["https://github.com/w159/clippy", "let value = getUserName(id)", "C++ templates",
                     "c sharp notes", "wire transfer approved", "transfer wire draft", "mail jo@example.com",
                     "Invoice for the Caf\u{e9}", "reinvoiced", "wow!!! really"]
        for text in texts {
            var clip = makeTextClip(text)
            clip.sourceAppName = "Safari"
            try db.saveCapturedClip(&clip, cap: 100)
        }
        let all = try db.allClips()
        for query in ["hub", "UserName", "c++", "c", "-hub", "\"wire transfer\"", "wire -draft", "@", "!!!",
                      "inv", "cafe", "INVOICE", "safari", "w159/clip", "zzz"] {
            let database = Set(try db.searchClips(matching: query, limit: 100).map(\.contentText))
            let local = Set(all.filter { $0.matchesLocally(query: query) }.map(\.contentText))
            XCTAssertEqual(database, local, "query \(query)")
        }
    }

    // MARK: - Cursor

    func testNewQueryResultsSelectTheTopMatch() {
        let results = [clip(7), clip(3), clip(9)]
        // The previously selected clip (9) is in the new results, but a new
        // query means the best match is what Return should paste.
        XCTAssertEqual(ResultSelectionPolicy.index(in: results, anchor: 9, followsTop: true), 0)
    }

    func testBackgroundPulseKeepsTheCursorOnTheSameClip() {
        let results = [clip(10), clip(7), clip(3), clip(9)]
        XCTAssertEqual(ResultSelectionPolicy.index(in: results, anchor: 9, followsTop: false), 3)
        XCTAssertEqual(ResultSelectionPolicy.index(in: results, anchor: 42, followsTop: false), 0)
        XCTAssertEqual(ResultSelectionPolicy.index(in: [], anchor: 9, followsTop: false), 0)
    }

    // MARK: - Return before the debounce fires

    func testPendingSearchIsReportedAndCanBeRunImmediately() throws {
        let db = try makeTestDatabase(self)
        for text in ["alpha one", "beta two"] {
            var clip = makeTextClip(text)
            try db.saveCapturedClip(&clip, cap: 100)
        }
        let store = ClipStore(database: db)
        waitFor("initial") { store.clips.count == 2 }
        XCTAssertFalse(store.hasPendingSearch)

        store.query = "beta"
        XCTAssertTrue(store.hasPendingSearch, "results still belong to the empty query during the debounce")
        let started = Date()
        store.searchNow()
        waitFor("search ran") { !store.hasPendingSearch }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.18, "searchNow must not wait out the debounce")
        XCTAssertEqual(store.clips.map(\.contentText), ["beta two"])
        XCTAssertEqual(store.completedQuery, "beta")

        store.query = "   "
        XCTAssertFalse(store.hasPendingSearch, "a blank query is the browse list, applied immediately")
        XCTAssertEqual(store.clips.count, 2)
    }
}

private extension Clip {
    func withID(_ id: Int64) -> Clip {
        var copy = self
        copy.id = id
        return copy
    }
}
