import Foundation

/// One ranked candidate list fed into `RankFusion`, best first.
struct RankedList: Equatable {
    /// Clip ids, best first. Repeats after the first occurrence are ignored.
    var ids: [Int64]
    /// Relative influence of this list; values <= 0 or non-finite disable it.
    var weight: Double

    init(ids: [Int64], weight: Double = 1) {
        self.ids = ids
        self.weight = weight
    }
}

/// One fused candidate.
struct FusedResult: Equatable {
    var id: Int64
    /// Sum of `weight / (k + rank)` over the lists that contain the id.
    var score: Double
    /// Best (lowest) 1-based rank across the contributing lists.
    var bestRank: Int
    /// Indices into the input `lists` that contained the id.
    var listIndices: [Int]
}

/// Reciprocal-rank fusion (Cormack et al.): merges ranked lists without needing
/// comparable scores. Pure and deterministic.
enum RankFusion {
    /// The conventional RRF damping constant.
    static let defaultDamping = 60.0

    /// Fuses `lists`; the result is best first. Ties break by best rank, then id.
    /// Empty, missing or zero-weight lists are skipped. `limit` caps the output.
    static func fuse(_ lists: [RankedList], damping dampingConstant: Double = defaultDamping, limit: Int? = nil) -> [FusedResult] {
        let damping = max(0, dampingConstant)
        var byID: [Int64: FusedResult] = [:]
        for (index, list) in lists.enumerated() where list.weight > 0 && list.weight.isFinite {
            var seen = Set<Int64>()
            var rank = 0
            for id in list.ids where seen.insert(id).inserted {
                rank += 1
                var entry = byID[id] ?? FusedResult(id: id, score: 0, bestRank: rank, listIndices: [])
                entry.score += list.weight / (damping + Double(rank))
                entry.bestRank = min(entry.bestRank, rank)
                entry.listIndices.append(index)
                byID[id] = entry
            }
        }
        let sorted = byID.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.bestRank != rhs.bestRank { return lhs.bestRank < rhs.bestRank }
            return lhs.id < rhs.id
        }
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }
}
