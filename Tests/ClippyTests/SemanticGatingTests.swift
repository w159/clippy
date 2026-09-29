import XCTest
@testable import Clippy

final class SemanticGatingTests: XCTestCase {
    private struct Probe: SemanticAssetProbe { var hasAvailableAssets: Bool }

    /// Deterministic embedder: bag of letters a-d.
    private struct StubEmbedder: TextEmbedder {
        func vector(for text: String) -> [Float]? {
            let counts = "abcd".map { letter in Float(text.lowercased().filter { $0 == letter }.count) }
            return counts.contains { $0 > 0 } ? counts : nil
        }
    }

    func testAvailabilityRequiresOptInThenAssets() {
        XCTAssertEqual(SemanticAvailability.evaluate(isEnabled: false, probe: Probe(hasAvailableAssets: true)), .disabledByUser)
        XCTAssertEqual(SemanticAvailability.evaluate(isEnabled: true, probe: Probe(hasAvailableAssets: false)), .assetsMissing)
        XCTAssertEqual(SemanticAvailability.evaluate(isEnabled: true, probe: Probe(hasAvailableAssets: true)), .ready)
    }

    func testPreferencesDefaultOffAndPersist() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "semantic-gating-\(UUID().uuidString)"))
        let prefs = SemanticSearchPreferences(defaults: suite)
        XCTAssertFalse(prefs.isEnabled)
        XCTAssertFalse(prefs.isAutoFileEnabled)
        XCTAssertFalse(prefs.isFoundationRefinementEnabled)
        prefs.isEnabled = true
        XCTAssertTrue(SemanticSearchPreferences(defaults: suite).isEnabled)
    }

    func testDescribeAvailabilityNeedsAllThreeProbes() {
        XCTAssertTrue(DescribeAvailability(osSupportsImageInput: true, modelAvailable: true, modelSupportsVision: true).canUseGenerative)
        XCTAssertFalse(DescribeAvailability(osSupportsImageInput: true, modelAvailable: true, modelSupportsVision: false).canUseGenerative)
        XCTAssertFalse(DescribeAvailability(osSupportsImageInput: false, modelAvailable: true, modelSupportsVision: true).canUseGenerative)
    }

    func testEligibleDropsSensitiveEmptyAndCaps() {
        var items = (1...(SemanticSearch.candidateCap + 10)).map { SemanticCandidate(id: Int64($0), text: "a", isSensitive: false) }
        items[0].isSensitive = true
        items[1].text = "  "
        let kept = SemanticSearch.eligible(items)
        XCTAssertEqual(kept.count, SemanticSearch.candidateCap)
        XCTAssertEqual(kept.first?.id, 3)
    }

    func testSensitiveClipsAreNeverEmbeddedAndHybridTagsSources() {
        let cache = EmbeddingCache(fileURL: nil, revision: 0)
        let search = SemanticSearch(embedder: StubEmbedder(), cache: cache)
        let candidates = [
            SemanticCandidate(id: 1, text: "aaaa", isSensitive: false),
            SemanticCandidate(id: 2, text: "aaab", isSensitive: true),
            SemanticCandidate(id: 3, text: "dddd", isSensitive: false),
        ]
        search.index(candidates)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(search.progress.total, 2)
        XCTAssertFalse(search.progress.isRunning)
        let results = search.hybridSearch(
            query: "aaa", ftsRankedIDs: [3, 1], candidates: candidates, availability: .ready)
        XCTAssertEqual(results.first { $0.clipID == 1 }?.matchedIn, .hybrid)
        XCTAssertEqual(results.first { $0.clipID == 3 }?.matchedIn, .fullText)
        XCTAssertNil(results.first { $0.clipID == 2 })
        let off = search.hybridSearch(query: "aaa", ftsRankedIDs: [3], candidates: candidates, availability: .disabledByUser)
        XCTAssertEqual(off.map(\.matchedIn), [.fullText])
    }
}
