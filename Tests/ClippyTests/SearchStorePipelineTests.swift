import Combine
import XCTest
@testable import Clippy

/// ClipStore's search pipeline: stale results after a failure, DB pulses during a
/// search, the semantic merge's lifecycle, and the category pane's query cache.
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
        store.recents = store.recents
        XCTAssertEqual(store.refilterToken, token, "an unchanged window must leave the search alone")
        store.recents = store.recents + [clip(99, "alpha fresh")]
        XCTAssertNotEqual(store.refilterToken, token, "a changed window refreshes the search")
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

        var emissions: [[Clip]] = []
        var matchEmissions = 0
        let clipsSink = store.$clips.dropFirst().sink { emissions.append($0) }
        let matchesSink = store.$semanticMatches.dropFirst().sink { _ in matchEmissions += 1 }
        let before = store.semanticCompletedRunID
        store.retrySearch()
        waitFor("refreshed merge finished") { store.semanticCompletedRunID > before }
        clipsSink.cancel()
        matchesSink.cancel()

        XCTAssertTrue(emissions.isEmpty, "the list must not be republished for an unchanged result")
        XCTAssertEqual(matchEmissions, 0, "badges must not be cleared and restored")
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

        var emissions: [[Clip]] = []
        let sink = store.$clips.dropFirst().sink { emissions.append($0) }
        let token = store.refilterToken
        for run in 1...5 {
            var marked = keywordClip
            marked.userTitle = "run \(run)"
            store.scheduleSemanticMerge(query: "quartz marble", token: token, keyword: [marked])
        }
        waitFor("last merge finished") { store.semanticCompletedRunID == 5 }
        sink.cancel()

        XCTAssertEqual(emissions.count, 1, "stale merges must not publish")
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
