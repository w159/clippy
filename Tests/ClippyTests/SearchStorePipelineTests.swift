import XCTest
@testable import Clippy

/// ClipStore's search pipeline: stale results after a failure, DB pulses during a
/// search, the semantic merge's lifecycle, and the category pane's query cache.
/// Counts search runs from the detached runner.
private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor
final class SearchStorePipelineTests: XCTestCase {
    private struct Boom: Error {}

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let done = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if condition() { timer.invalidate(); done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
        timer.invalidate()
    }

    private func seed(_ db: ClipDatabase, _ texts: [String]) throws {
        let base = Date().addingTimeInterval(-1000)
        for (index, text) in texts.enumerated() {
            var clip = makeTextClip(text, createdAt: base.addingTimeInterval(Double(index)))
            try db.saveCapturedClip(&clip, cap: 1000)
        }
    }

    private func clip(_ id: Int64, _ text: String) -> Clip {
        var clip = makeTextClip(text)
        clip.id = id
        return clip
    }

    private func semanticEnvironment() -> SemanticSearchEnvironment {
        let engine = SemanticSearch(embedder: LanguageStubEmbedder(), cache: EmbeddingCache(fileURL: nil, revision: 0))
        return SemanticSearchEnvironment(isEnabled: { true }, availability: { .ready }, engine: { engine })
    }

    // MARK: - Failure

    /// Seeded fault: the failure branch set `completedQuery` to the new text over the
    /// previous query's results, so Return pasted the old query's top clip.
    func testFailedSearchDoesNotLeaveTheOldQuerysResultsPasteable() throws {
        let db = try makeTestDatabase(self)
        try seed(db, ["alpha one", "beta two"])
        let store = ClipStore(database: db)
        waitFor("initial") { store.clips.count == 2 }
        store.query = "alpha"
        waitFor("alpha landed") { !store.hasPendingSearch }
        XCTAssertEqual(store.clips.map(\.contentText), ["alpha one"])

        store.searchRunner = { _, _, _ in throw Boom() }
        store.query = "beta"
        waitFor("failure landed") { store.searchError != nil }
        XCTAssertEqual(store.completedQuery, "beta")
        XCTAssertTrue(store.clips.isEmpty, "results of 'alpha' must not stand in for 'beta'")
    }

    // MARK: - Pulses

    /// Seeded fault: every observation pulse called `refilter()`, restarting the
    /// running search even when the window was unchanged.
    func testIdenticalWindowPulseDoesNotRestartTheSearch() throws {
        let db = try makeTestDatabase(self)
        try seed(db, ["alpha one", "beta two"])
        let store = ClipStore(database: db)
        waitFor("initial") { store.clips.count == 2 }
        store.query = "alpha"
        waitFor("alpha landed") { !store.hasPendingSearch }

        let token = store.refilterToken
        let unchanged = store.recents
        store.recents = unchanged
        XCTAssertEqual(store.refilterToken, token, "an unchanged window must leave the search alone")
        store.recents = store.recents + [clip(99, "alpha fresh")]
        waitFor("a changed window refreshes the search") { store.refilterToken != token }
    }

    /// Seeded fault: every changed window re-ran the whole search at once, so a burst of captures or OCR
    /// writes during a query repeated it per pulse. The runner count is the observable.
    func testBurstOfChangedWindowsRunsTheSearchOnce() throws {
        let db = try makeTestDatabase(self)
        try seed(db, ["alpha one", "beta two"])
        let store = ClipStore(database: db)
        waitFor("initial") { store.clips.count == 2 }
        store.query = "alpha"
        waitFor("alpha landed") { !store.hasPendingSearch }

        let runs = RunCounter()
        store.searchRunner = { database, query, limit in
            runs.increment()
            return try database.searchClips(matching: query, limit: limit)
        }
        for number in 1...5 {
            store.recents = store.recents + [clip(Int64(100 + number), "alpha pulse \(number)")]
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let same = store.recents
        for _ in 1...5 { store.recents = same }
        waitFor("the coalesced search ran") { runs.value >= 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(runs.value, 1, "pulses inside the throttle window share one search")
    }

    // MARK: - Semantic merge

    /// Seeded fault: each pulse republished keyword-only order with the semantic badges cleared, then
    /// the fused order again. Clip X below is a semantic-only hit, so keyword order lacks it.
    func testPulseKeepsTheFusedOrderOnScreen() throws {
        let db = try makeTestDatabase(self)
        try seed(db, ["marble", "quartz marble falcon"])
        let store = ClipStore(database: db)
        store.semanticEnvironment = semanticEnvironment()
        waitFor("initial") { store.clips.count == 2 }
        store.query = "quartz marble"
        waitFor("fused landed") { store.semanticCompletedRunID >= 1 && store.clips.count == 2 }
        XCTAssertEqual(store.fusedQuery, "quartz marble")
        let fused = store.clips
        let matches = store.semanticMatches
        XCTAssertFalse(matches.isEmpty)

        let clipsRecorder = ChangeRecorder(tracking: { _ = store.clips })
        let assignsBefore = store.semanticMatchesAssignCount
        let before = store.semanticCompletedRunID
        store.retrySearch()
        waitFor("refreshed merge finished") { store.semanticCompletedRunID > before }
        clipsRecorder.cancel()

        XCTAssertEqual(clipsRecorder.count, 0, "the list must not be republished for an unchanged result")
        XCTAssertEqual(store.semanticMatchesAssignCount, assignsBefore, "badges must not be cleared and restored")
        XCTAssertEqual(store.clips, fused)
        XCTAssertEqual(store.semanticMatches, matches)
    }

    /// Seeded fault: the detached merge was never stored or cancelled, so every call ran and published.
    /// Only the newest of several rapid merges may publish; its keyword clip carries a marker title.
    func testOnlyTheNewestRapidMergePublishes() throws {
        let db = try makeTestDatabase(self)
        try seed(db, ["marble", "quartz marble falcon"])
        let store = ClipStore(database: db)
        store.semanticEnvironment = semanticEnvironment()
        waitFor("initial") { store.clips.count == 2 }
        let keywordClip = try XCTUnwrap(store.clips.first { $0.contentText.hasPrefix("quartz") })

        let recorder = ChangeRecorder(tracking: { _ = store.clips })
        let token = store.refilterToken
        for run in 1...5 {
            var marked = keywordClip
            marked.userTitle = "run \(run)"
            store.scheduleSemanticMerge(query: "quartz marble", token: token, keyword: [marked])
        }
        waitFor("last merge finished") { store.semanticCompletedRunID == 5 }
        recorder.cancel()

        XCTAssertEqual(recorder.count, 1, "stale merges must not publish")
        XCTAssertEqual(store.clips.first { $0.id == keywordClip.id }?.userTitle, "run 5")
    }

    // MARK: - Engine cancellation

    /// Seeded fault: `index` cleared the cancel flag on entry, so a cancel issued
    /// before the run started was lost and the run embedded everything.
    func testCancelBeforeIndexStartsIsNotClobbered() {
        let cache = EmbeddingCache(fileURL: nil, revision: 0)
        let search = SemanticSearch(embedder: LanguageStubEmbedder(), cache: cache)
        let candidates = (1...5).map { SemanticCandidate(id: Int64($0), text: "quartz marble \($0)", isSensitive: false) }
        search.cancelIndexing()
        search.index(candidates)
        XCTAssertEqual(cache.count, 0)
        // The request is spent by that run; the next one indexes normally.
        search.index(candidates)
        XCTAssertEqual(cache.count, 5)
    }

    // MARK: - Category pane

    /// Seeded fault: the pane filtered `recents` in memory, so a clip only the database search finds
    /// (full text or OCR text) or one outside the loaded window was missing from its own pane.
    func testCategoryPaneFindsWhatTheHistorySearchFinds() throws {
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        let inWindow = clip(1, "unrelated words")
        let outside = clip(2, "other words")
        store.recents = [inWindow]
        store.categoryClipOrder = [7: [2, 1]]
        store.searchRunner = { _, _, _ in [inWindow, outside] }

        store.query = "needle"
        waitFor("search landed") { !store.hasPendingSearch }
        XCTAssertEqual(store.clipsForCategory(7).map(\.id), [2, 1],
                       "both hits show in the pane, in the category's own order")

        store.searchRunner = { _, _, _ in [] }
        store.query = "needle two"
        waitFor("second search landed") { !store.hasPendingSearch }
        XCTAssertEqual(store.clipsForCategory(7).map(\.id), [], "no search hit and no local match: nothing")
    }

    /// Seeded fault: every clip of every render re-parsed the query. The parse count is the observable.
    func testCategoryPaneParsesOncePerQueryAndMatchesTheDirectFilter() throws {
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        let clips = [clip(1, "alpha one"), clip(2, "beta two"), clip(3, "alpha three"), clip(4, "gamma")]
        store.recents = clips
        store.categoryClipOrder = [7: [4, 3, 2, 1], 8: [1, 2]]

        store.query = "alpha"
        let expected7 = [4, 3, 2, 1].compactMap { id in clips.first { $0.id == Int64(id) } }
            .filter { $0.matchesLocally(query: "alpha") }.map(\.id)
        for _ in 0..<5 {
            XCTAssertEqual(store.clipsForCategory(7).map(\.id), expected7)
            XCTAssertEqual(store.clipsForCategory(8).map(\.id), [1])
        }
        XCTAssertEqual(store.localQueryParseCount, 1, "one parse for the query, not one per clip or per render")

        // New data under the same query: recomputed from the new data, same parse.
        store.recents = clips + [clip(5, "alpha five")]
        store.categoryClipOrder[7] = [5, 4, 3, 2, 1]
        XCTAssertEqual(store.clipsForCategory(7).map(\.id), [5, 3, 1])
        XCTAssertEqual(store.localQueryParseCount, 1)

        store.query = "beta"
        XCTAssertEqual(store.clipsForCategory(7).map(\.id), [2])
        XCTAssertEqual(store.localQueryParseCount, 2)

        store.query = ""
        XCTAssertEqual(store.clipsForCategory(7).map(\.id), [5, 4, 3, 2, 1])
    }
}
