import NaturalLanguage
import XCTest
@testable import Clippy

/// Ranker calibration against the SYNTHETIC fixture (see `SuggestionTuning` for the
/// procedure and the measured numbers). Uses the real `NLTextEmbedder`; skipped
/// when the sentence embedding is unavailable on this machine.
final class SuggestionCalibrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Metrics { var precisionAt3 = 0.0; var recallAt5 = 0.0 }

    private func measure(engine: SuggestionEngine) -> Metrics {
        let clips: [Clip] = SuggestionCalibrationFixture.pool.enumerated().map { index, entry in
            makeIntelClip(
                Int64(index + 1), entry.text, age: TimeInterval(3600 + index * 60), now: now,
                bundle: "com.example.src")
        }
        let cases = SuggestionCalibrationFixture.cases
        var metrics = Metrics()
        for entry in cases {
            let context = ScreenContext(
                appName: "Notes", bundleID: "com.apple.Notes", text: entry.context, capturedAt: now)
            let ids = engine.rank(context: context, clips: clips, limit: 5, now: now)
                .map { Int($0.clip.id! - 1) }
            metrics.precisionAt3 += Double(ids.prefix(3).filter(entry.relevant.contains).count) / 3
            metrics.recallAt5 +=
                Double(ids.prefix(5).filter(entry.relevant.contains).count) / Double(entry.relevant.count)
        }
        metrics.precisionAt3 /= Double(cases.count)
        metrics.recallAt5 /= Double(cases.count)
        return metrics
    }

    func testFixtureIsLargeEnoughAndSyntheticallyBalanced() {
        let cases = SuggestionCalibrationFixture.cases
        XCTAssertGreaterThanOrEqual(cases.reduce(0) { $0 + $1.relevant.count }, 40)
        XCTAssertEqual(Set(cases.map(\.topic)), ["travel", "finance", "code", "meetings", "shopping"])
        for entry in cases {
            XCTAssertEqual(entry.relevant.count, 2)
            XCTAssertTrue(entry.relevant.allSatisfy { $0 < SuggestionCalibrationFixture.pool.count })
        }
    }

    func testRealEmbedderMeetsPrecisionAndRecallFloors() throws {
        try XCTSkipUnless(
            NLTextEmbedder.hasSentenceEmbedding(for: .english), "NLEmbedding sentence model unavailable")
        let metrics = measure(engine: SuggestionEngine(embedder: NLTextEmbedder()))
        // Measured 0.478 / 0.767 (ceiling for P@3 is 0.667); floors leave headroom for
        // embedding revisions. Re-derive per the procedure in SuggestionTuning.
        XCTAssertGreaterThanOrEqual(metrics.precisionAt3, 0.40, "precision@3 \(metrics.precisionAt3)")
        XCTAssertGreaterThanOrEqual(metrics.recallAt5, 0.65, "recall@5 \(metrics.recallAt5)")
    }

    func testTuningConstantsAreSane() {
        XCTAssertGreaterThan(SuggestionTuning.embeddingSpan, 0)
        XCTAssertTrue((0..<1).contains(SuggestionTuning.embeddingFloor))
        XCTAssertLessThan(SuggestionTuning.notRelevantWeight, 1)
    }
}
