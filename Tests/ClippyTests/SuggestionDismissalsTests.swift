import XCTest
@testable import Clippy

final class SuggestionDismissalsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func engine(_ dismissals: SuggestionDismissals) -> SuggestionEngine {
        SuggestionEngine(embedder: LanguageStubEmbedder(), dismissals: dismissals)
    }

    private func context(_ text: String, bundle: String = "com.other") -> ScreenContext {
        ScreenContext(appName: "Notes", bundleID: bundle, text: text, capturedAt: now)
    }

    private let query = "quarterly invoice payment reminder"

    func testNeverSuggestRemovesClipFromRankAndRelated() {
        let dismissals = SuggestionDismissals(fileURL: nil)
        let keep = makeIntelClip(1, "quarterly invoice payment terms", now: now)
        let hide = makeIntelClip(2, "quarterly invoice payment overdue", now: now)
        dismissals.neverSuggest(hide)
        let engine = engine(dismissals)
        XCTAssertEqual(
            engine.rank(context: context(query), clips: [keep, hide], limit: 5, now: now).map(\.id), [1])
        let seed = makeIntelClip(3, "quarterly invoice payment reminder draft", now: now)
        XCTAssertEqual(
            engine.related(to: seed, clips: [keep, hide], limit: 5, now: now).map(\.id), [1])
    }

    func testKeyIsContentHashNotClipID() {
        let dismissals = SuggestionDismissals(fileURL: nil)
        let original = makeIntelClip(2, "quarterly invoice payment overdue", now: now)
        dismissals.neverSuggest(original)
        // Same content re-copied under a new row id stays dismissed.
        let recopied = makeIntelClip(99, "quarterly invoice payment overdue", age: 5, now: now)
        XCTAssertTrue(
            engine(dismissals).rank(context: context(query), clips: [recopied], limit: 5, now: now).isEmpty)
    }

    func testNotRelevantDownWeightsThenExpires() {
        let dismissals = SuggestionDismissals(fileURL: nil)
        let termsClip = makeIntelClip(1, "quarterly invoice payment terms", age: 60, now: now)
        let overdueClip = makeIntelClip(2, "quarterly invoice payment overdue", age: 120, now: now)
        let engine = engine(dismissals)
        let before = engine.rank(context: context(query), clips: [termsClip, overdueClip], limit: 5, now: now)
        XCTAssertEqual(before.first?.id, 1)

        dismissals.markNotRelevant(termsClip, days: 7, now: now)
        let during = engine.rank(context: context(query), clips: [termsClip, overdueClip], limit: 5, now: now)
        XCTAssertEqual(during.first?.id, 2, "demoted clip drops below the other")
        let demoted = during.first { $0.id == 1 }?.score ?? 0
        XCTAssertLessThan(demoted, before.first { $0.id == 1 }!.score)

        let later = now.addingTimeInterval(8 * 86_400)
        XCTAssertTrue(dismissals.entries(now: later).isEmpty)
        XCTAssertEqual(dismissals.entries(now: now).count, 1)
        let after = engine.rank(context: context(query), clips: [termsClip, overdueClip], limit: 5, now: later)
        XCTAssertEqual(after.first?.id, 1, "expired mark no longer down-weights")
    }

    func testNeverWinsOverNotRelevantAndRestoreUndoes() {
        let dismissals = SuggestionDismissals(fileURL: nil)
        dismissals.neverSuggest(contentKey: "k")
        dismissals.markNotRelevant(contentKey: "k", days: 3, now: now)
        XCTAssertEqual(dismissals.entries(now: now), [.init(contentKey: "k", kind: .never, until: nil)])
        dismissals.restore(contentKey: "k")
        XCTAssertTrue(dismissals.entries(now: now).isEmpty)
    }

    func testExcludedAppYieldsNoSuggestions() {
        let dismissals = SuggestionDismissals(fileURL: nil)
        dismissals.excludeApp("com.other")
        let clips = [makeIntelClip(1, "quarterly invoice payment terms", now: now)]
        let engine = engine(dismissals)
        XCTAssertTrue(engine.rank(context: context(query), clips: clips, limit: 5, now: now).isEmpty)
        XCTAssertFalse(engine.rank(context: context(query, bundle: "com.third"), clips: clips, limit: 5, now: now).isEmpty)
        dismissals.includeApp("com.other")
        XCTAssertFalse(engine.rank(context: context(query), clips: clips, limit: 5, now: now).isEmpty)
        XCTAssertEqual(dismissals.excludedApps(), [])
    }

    func testPersistenceRoundTripAndCorruptFile() throws {
        let url = makeIntelligenceTempDirectory(self).appendingPathComponent("d.json")
        let first = SuggestionDismissals(fileURL: url)
        first.neverSuggest(contentKey: "abc")
        first.markNotRelevant(contentKey: "def", days: 5, now: now)
        first.excludeApp("com.example.app")

        let second = SuggestionDismissals(fileURL: url)
        XCTAssertEqual(Set(second.entries(now: now).map(\.contentKey)), ["abc", "def"])
        XCTAssertEqual(second.excludedApps(), ["com.example.app"])
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("quarterly"), "no clip text is stored")

        try Data("{not json".utf8).write(to: url)
        XCTAssertTrue(SuggestionDismissals(fileURL: url).entries(now: now).isEmpty)
    }
}
