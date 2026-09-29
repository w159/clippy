import XCTest
@testable import Clippy

final class SuggestionLanguageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(_ text: String) -> ScreenContext {
        ScreenContext(appName: "Notes", bundleID: "com.other", text: text, capturedAt: now)
    }

    func testSameLanguageComparesAndReportsLanguage() {
        let engine = SuggestionEngine(embedder: LanguageStubEmbedder())
        let clips = [makeIntelClip(1, "lisbon itinerary flights hotel booking", now: now)]
        let ranked = engine.rank(
            context: context("planning lisbon flights itinerary hotel"), clips: clips, limit: 3, now: now)
        XCTAssertEqual(ranked.first?.clip.id, 1)
        XCTAssertEqual(ranked.first?.embeddingLanguage, "en")
    }

    func testDifferentLanguagesAreNeverCompared() {
        let engine = SuggestionEngine(embedder: LanguageStubEmbedder())
        // Identical vocabulary but the clip is Spanish-tagged: no embedding credit,
        // no language reported, and no "similar" reason.
        let spanish = makeIntelClip(1, "hola lisbon itinerary flights hotel booking", age: 4 * 86_400, now: now)
        let english = makeIntelClip(2, "lisbon itinerary flights hotel booking", age: 4 * 86_400, now: now)
        let ranked = engine.rank(
            context: context("lisbon itinerary flights hotel booking plans"),
            clips: [spanish, english], limit: 5, now: now)
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        XCTAssertEqual(byID[2]?.embeddingLanguage, "en")
        XCTAssertNil(byID[1]?.embeddingLanguage)
        XCTAssertGreaterThan(byID[2]?.score ?? 0, byID[1]?.score ?? 1)
    }

    func testUnsupportedLanguageFallsBackToKeywordSignals() {
        let engine = SuggestionEngine(embedder: LanguageStubEmbedder())
        let clips = [
            makeIntelClip(1, "zzz quarterly invoice number", age: 3600, now: now),
            makeIntelClip(2, "zzz grocery list eggs", age: 3600, now: now),
        ]
        let ranked = engine.rank(
            context: context("zzz send the quarterly invoice"), clips: clips, limit: 5, now: now)
        XCTAssertEqual(ranked.first?.clip.id, 1)
        XCTAssertNil(ranked.first?.embeddingLanguage)
        XCTAssertTrue(ranked.first?.reason.hasPrefix("Shares words") ?? false)
    }

    func testLanguageIsPersistedWithCachedVector() {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("e.bin")
        let cache = EmbeddingCache(fileURL: url, revision: 1, saveDelay: 60)
        let engine = SuggestionEngine(embedder: LanguageStubEmbedder(), cache: cache)
        let clip = makeIntelClip(1, "hola lisbon itinerary flights", now: now)
        _ = engine.rank(context: context("hola lisbon itinerary"), clips: [clip], limit: 3, now: now)
        cache.flush()
        let reloaded = EmbeddingCache(fileURL: url, revision: 1, saveDelay: 60)
        let text = "hola lisbon itinerary flights"
        XCTAssertEqual(reloaded.lookup(id: 1, textHash: StableHash.fnv1a(text))?.language, "es")
    }

    func testNLEmbedderHasNoVectorForUnsupportedLanguageAndTagsSupportedOnes() throws {
        try XCTSkipUnless(NLTextEmbedder.hasSentenceEmbedding(for: .english), "No English sentence embedding")
        let embedder = NLTextEmbedder()
        let vector = embedder.embedding(
            for: "Planning our trip to Lisbon next month, we still need to book flights and a hotel")
        XCTAssertEqual(vector?.language, "en")
        XCTAssertNil(embedder.embedding(for: "   "))
    }
}
