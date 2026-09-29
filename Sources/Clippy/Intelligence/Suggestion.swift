import Foundation

/// One ranked clipboard suggestion.
struct Suggestion: Identifiable, Equatable {
    let clip: Clip
    /// 0...1 blended relevance.
    let score: Double
    /// Short human-readable why, e.g. "Similar to what you're writing", "Copied from Safari",
    /// "Shares words: Lisbon, itinerary", "Recent link". Never contains raw screen text.
    var reason: String
    /// Language space (`NLLanguage.rawValue`) the embedding comparison used, or nil when this
    /// suggestion was ranked without an embedding (keyword/recency/app signals only).
    var embeddingLanguage: String? = nil
    /// True when the optional Apple Intelligence second stage (INT-06) wrote `reason`.
    var isRefined: Bool = false
    var id: Int64 { clip.id ?? -1 }
}
