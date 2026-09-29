import Foundation

/// Every tunable constant of the suggestion ranker in one documented place.
///
/// ## Calibration procedure (ROADMAP INT-03)
/// 1. `SuggestionCalibrationTests` holds a labelled SYNTHETIC fixture (no real
///    data): for each of five topics (travel, finance-generic, code, meetings,
///    shopping) a set of contexts, each with relevant clips and distractors.
/// 2. The test ranks every context against the whole clip pool with the real
///    `NLTextEmbedder` and reports precision@3 and recall@5.
/// 3. To re-derive `embeddingFloor`/`embeddingSpan`: print the cosine of every
///    relevant pair and every unrelated pair (the test's `distribution` helper),
///    set the floor just above the 95th percentile of the unrelated cosines and
///    the span to (median of relevant cosines - floor) * 1.5, then re-run and
///    confirm the asserted thresholds still hold.
/// 4. Re-run whenever `NLTextEmbedder.revision` changes.
///
/// Measured on the fixture set (see `SuggestionCalibrationTests`):
/// - 30 contexts / 60 labelled pairs / pool of 30 clips, English, macOS 26 SDK
///   sentence-embedding revisions as of 2026-09.
/// - Hybrid ranker at floor 0.36, span 0.12: precision@3 = 0.478 (ceiling 0.667, two
///   relevant clips per context), recall@5 = 0.767.
/// - Cosine distribution: relevant median 0.542 (p10 0.343, p90 0.700); unrelated
///   median 0.333, p95 0.547, max 0.742. Unrelated pairs from the SAME topic score
///   high, so the distributions overlap and the floor cannot separate them alone.
/// - Sweep (floor/span -> P@3, R@5): 0.36/0.12 -> 0.478, 0.767; 0.40/0.15 -> 0.456, 0.767;
///   0.45/0.15 -> 0.433, 0.750; 0.50/0.20 -> 0.444, 0.717; 0.30/0.12 -> 0.456, 0.733;
///   0.25/0.30 -> 0.467, 0.750; 0.20/0.40 -> 0.444, 0.750. 0.36/0.12 was best, so the
///   original constants are kept; the test asserts P@3 >= 0.40 and R@5 >= 0.65.
enum SuggestionTuning {
    /// Cosine below which a pair is treated as unrelated noise.
    static let embeddingFloor = 0.36
    /// Cosine range above the floor that maps onto a 0...1 embedding score.
    static let embeddingSpan = 0.12
    /// Candidates scoring below this are dropped so garbage is never shown.
    static let minScore = 0.2
    /// Recency half-life for the recency signal.
    static let recencyHalfLife: TimeInterval = 3 * 24 * 3600
    /// Maximum number of vectors kept in the embedding cache (memory and disk).
    static let cacheCapacity = 2000
    /// Characters of a clip that are embedded.
    static let clipEmbedChars = 500

    // MARK: Feedback (INT-07)

    /// Score multiplier for a clip marked "not relevant" while its entry lasts.
    static let notRelevantWeight = 0.3
    /// Default number of days a "not relevant" mark down-weights a clip.
    static let notRelevantDays = 14

    // MARK: Second stage (INT-06)

    /// How many top candidates the optional second stage may re-rank.
    static let secondStageCandidates = 20
    /// Hard wall-clock budget for the second stage; on expiry the base ranking is used.
    static let secondStageTimeout: TimeInterval = 3

    /// UserDefaults key for `useFoundationModels`.
    static let useFoundationModelsKey = "clippy.suggestions.useFoundationModels"

    /// Opt-in: re-rank the top candidates and phrase the reason with Apple's
    /// on-device Foundation Models. Default false. Even when true it only runs
    /// while `SystemLanguageModel.default.availability == .available`. Nothing
    /// leaves the device.
    static var useFoundationModels: Bool {
        get { UserDefaults.standard.bool(forKey: useFoundationModelsKey) }
        set { UserDefaults.standard.set(newValue, forKey: useFoundationModelsKey) }
    }
}
