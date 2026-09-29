import XCTest
@testable import Clippy

/// Deterministic bag-of-words hashing embedder: no NaturalLanguage dependency.
private struct StubEmbedder: TextEmbedder {
    let dimensions = 64
    func vector(for text: String) -> [Float]? {
        var vector = [Float](repeating: 0, count: dimensions)
        var any = false
        for word in SuggestionEngine.words(text) {
            var hash: UInt64 = 5381
            for byte in word.utf8 { hash = hash &* 33 &+ UInt64(byte) }
            vector[Int(hash % UInt64(dimensions))] += 1
            any = true
        }
        return any ? vector : nil
    }
}

/// Embedder that yields nothing, so only keyword/recency/app/kind signals count.
private struct NoEmbedder: TextEmbedder {
    func vector(for text: String) -> [Float]? { nil }
}

@MainActor
final class SuggestionEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var savedEnabled = false

    override func setUp() {
        super.setUp()
        savedEnabled = AppSettings.shared.suggestionsEnabled
    }

    override func tearDown() {
        AppSettings.shared.suggestionsEnabled = savedEnabled
        super.tearDown()
    }

    private func clip(
        _ id: Int64, _ text: String, age: TimeInterval = 60,
        bundle: String = "com.example.test", app: String = "TestApp"
    ) -> Clip {
        var clip = makeTextClip(text, createdAt: now.addingTimeInterval(-age))
        clip.id = id
        clip.sourceAppBundleID = bundle
        clip.sourceAppName = app
        return clip
    }

    private func context(_ text: String, bundle: String? = "com.other.app") -> ScreenContext {
        ScreenContext(appName: "Other", bundleID: bundle, windowTitle: nil, text: text, capturedAt: now)
    }

    func testRelatedClipOutranksUnrelated() {
        let engine = SuggestionEngine(embedder: StubEmbedder())
        let clips = [
            clip(1, "gardening tomatoes fertilizer watering"),
            clip(2, "lisbon itinerary flights hotel booking"),
        ]
        let ranked = engine.rank(
            context: context("planning the lisbon trip itinerary and flights"),
            clips: clips, limit: 5, now: now)
        XCTAssertEqual(ranked.first?.clip.id, 2)
    }

    func testKeywordOverlapSurfacesMatchWithoutEmbeddings() {
        let engine = SuggestionEngine(embedder: NoEmbedder())
        let clips = [
            clip(1, "quarterly invoice number 4471", age: 3600),
            clip(2, "unrelated grocery list eggs", age: 3600),
        ]
        let ranked = engine.rank(
            context: context("please send the quarterly invoice today"),
            clips: clips, limit: 5, now: now)
        XCTAssertEqual(ranked.first?.clip.id, 1)
        XCTAssertTrue(ranked.first?.reason.hasPrefix("Shares words") ?? false)
    }

    func testRecencyBreaksNearTies() {
        let engine = SuggestionEngine(embedder: StubEmbedder())
        let clips = [
            clip(1, "budget report", age: 10 * 86400),
            clip(2, "report budget", age: 60),
        ]
        let ranked = engine.rank(
            context: context("budget report review"), clips: clips, limit: 5, now: now)
        XCTAssertEqual(ranked.map(\.clip.id), [2, 1])
    }

    func testExcludesEmptyDuplicateAndContextEqualAndHonorsLimit() {
        let engine = SuggestionEngine(embedder: StubEmbedder())
        var clips = [
            clip(1, "   "),
            clip(2, "shipping address street"),
            clip(3, "Shipping Address Street", age: 500),
            clip(4, "the exact selected text here"),
        ]
        for id in 10..<20 { clips.append(clip(Int64(id), "shipping address street number \(id)")) }
        let ranked = engine.rank(
            context: context("the exact selected text here"), clips: clips, limit: 3, now: now)
        XCTAssertLessThanOrEqual(ranked.count, 3)
        let ids = Set(ranked.map(\.clip.id))
        XCTAssertFalse(ids.contains(1))
        XCTAssertFalse(ids.contains(4))
        let all = engine.rank(
            context: context("the exact selected text here"), clips: clips, limit: 50, now: now)
        XCTAssertFalse(all.contains { $0.clip.id == 3 }, "duplicate of clip 2 should be dropped")
        XCTAssertFalse(all.contains { $0.clip.id == 1 })
        XCTAssertFalse(all.contains { $0.clip.id == 4 })
    }

    func testSameSourceAppAffinityBoostsScore() {
        let engine = SuggestionEngine(embedder: NoEmbedder())
        let clips = [
            clip(1, "alpha bravo charlie", bundle: "com.apple.mail", app: "Mail"),
            clip(2, "delta echo foxtrot", bundle: "com.other.app", app: "Other"),
        ]
        let ranked = engine.rank(
            context: context("nothing shared here", bundle: "com.apple.mail"),
            clips: clips, limit: 5, now: now)
        XCTAssertEqual(ranked.first?.clip.id, 1)
        XCTAssertEqual(ranked.first?.reason, "Copied from Mail")
    }

    func testReasonsNeverLeakMoreThanThreeContextWords() {
        let engine = SuggestionEngine(embedder: StubEmbedder())
        let contextText = "lisbon itinerary flights hotel booking confirmation dinner reservation"
        let contextWords = Set(SuggestionEngine.words(contextText))
        let clips = [
            clip(1, "lisbon itinerary flights hotel booking confirmation"),
            clip(2, "lisbon dinner reservation"),
        ]
        let ranked = engine.rank(context: context(contextText), clips: clips, limit: 5, now: now)
        XCTAssertFalse(ranked.isEmpty)
        for suggestion in ranked {
            let leaked = SuggestionEngine.words(suggestion.reason).filter(contextWords.contains)
            XCTAssertLessThanOrEqual(leaked.count, 3, suggestion.reason)
        }
    }

    func testRefreshSuggestionsDisabledYieldsDisabledState() throws {
        AppSettings.shared.suggestionsEnabled = false
        let store = ClipStore(database: try makeTestDatabase(self))
        store.refreshSuggestions(context: context("anything at all"))
        XCTAssertEqual(store.suggestionsState, .disabled)
        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertNil(store.suggestionsContextSummary)
    }

    func testNLTextEmbedderReturns512Dimensions() throws {
        let vector = NLTextEmbedder().vector(for: "Planning a trip to Lisbon next spring.")
        try XCTSkipIf(vector == nil, "NLEmbedding sentence model unavailable")
        XCTAssertEqual(vector?.count, 512)
    }

    /// Real NLEmbedding + synthetic fixtures (no production data). Regression:
    /// min-max normalizing the cosine across candidates let the least-unrelated
    /// clip (a shell command) outrank a relevant link. Absolute scaling must keep
    /// unrelated noise below every relevant clip.
    func testRealEmbedderKeepsUnrelatedNoiseBelowRelevantClips() throws {
        try XCTSkipIf(NLTextEmbedder().vector(for: "probe sentence") == nil, "NLEmbedding unavailable")
        let engine = SuggestionEngine()
        let texts = [
            "https://travel.example.com/hotels/lisbon-central",
            "Flight AB 100 departs 9:40pm arrives Lisbon 9:55am, confirmation Z9Y8X7",
            "sudo systemctl restart example-service",
            "SELECT * FROM widgets WHERE owner_id = 7",
            "Hotel booking confirmation Lisbon check-in October 12",
            "Reference code 000000",
        ]
        let clips = texts.enumerated().map { index, text -> Clip in
            var clip = makeTextClip(text, createdAt: now.addingTimeInterval(-Double(index) * 3600))
            clip.id = Int64(index + 1)
            return clip
        }
        let ranked = engine.rank(
            context: context("Re: Trip to Lisbon\nCan you send the flight and hotel details for our trip?"),
            clips: clips, limit: 6, now: now)
        let order = ranked.map(\.clip.id)
        XCTAssertEqual(Set(order.prefix(2)), [2, 5], "flight and hotel confirmations should lead")
        for noisy in [3, 4, 6] as [Int64] {
            if let noisyIndex = order.firstIndex(of: noisy), let linkIndex = order.firstIndex(of: 1) {
                XCTAssertGreaterThan(noisyIndex, linkIndex, "unrelated clip \(noisy) outranked the relevant link")
            }
            XCTAssertNotEqual(
                ranked.first { $0.clip.id == noisy }?.reason, "Similar to what you're writing",
                "unrelated clip \(noisy) must not be labelled as similar")
        }
    }
}
