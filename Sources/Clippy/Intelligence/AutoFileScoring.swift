import Foundation

/// Mean embedding of the clips already filed in one category.
struct CategoryCentroid: Equatable {
    var categoryID: Int64
    var vector: [Float]
    /// `LanguageVector.language` of the space the centroid lives in.
    var language: String
    var memberCount: Int
}

/// A category proposal for one uncategorized clip. Never applied without accept.
struct AutoFileSuggestion: Equatable, Identifiable {
    var clipID: Int64
    var categoryID: Int64
    /// Cosine similarity to the category centroid, 0...1.
    var score: Float
    /// Short human-readable explanation, e.g. "Similar to 5 clips in Receipts".
    var reason: String

    var id: String { "\(clipID)-\(categoryID)" }
}

/// Pure centroid math and thresholds for auto-filing (FEAT-16).
enum AutoFileScoring {
    /// Categories with fewer filed clips than this get no centroid.
    static let minMembers = 3
    /// Minimum cosine similarity for a suggestion.
    static let similarityFloor: Float = 0.5

    /// One centroid per category. Members are restricted to the category's most
    /// common embedding language (vectors of different languages are not
    /// comparable). Categories below `minMembers` are omitted.
    static func centroids(members: [Int64: [LanguageVector]], minMembers: Int = minMembers) -> [CategoryCentroid] {
        var result: [CategoryCentroid] = []
        for (categoryID, vectors) in members {
            let byLanguage = Dictionary(grouping: vectors, by: \.language)
            guard let best = byLanguage.max(by: { lhs, rhs in
                lhs.value.count != rhs.value.count ? lhs.value.count < rhs.value.count : lhs.key > rhs.key
            }), best.value.count >= max(1, minMembers),
                let mean = VectorMath.mean(best.value.map(\.vector))
            else { continue }
            result.append(
                CategoryCentroid(categoryID: categoryID, vector: mean, language: best.key, memberCount: best.value.count))
        }
        return result.sorted { $0.categoryID < $1.categoryID }
    }

    /// Best-first (categoryID, similarity) pairs at or above `floor` in the
    /// vector's language, skipping `excluding`. Ties break by category id.
    static func ranked(
        _ vector: LanguageVector, against centroids: [CategoryCentroid], floor: Float = similarityFloor,
        excluding: Set<Int64> = []
    ) -> [(categoryID: Int64, score: Float)] {
        centroids.compactMap { centroid -> (Int64, Float)? in
            guard centroid.language == vector.language, !excluding.contains(centroid.categoryID) else { return nil }
            let score = VectorMath.cosine(vector.vector, centroid.vector)
            return score >= floor ? (centroid.categoryID, score) : nil
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
}
