import Foundation
import NaturalLanguage

/// Where a search hit came from, for UI badges.
enum SearchMatchSource: String, Equatable {
    case fullText
    case semantic
    /// Present in both the keyword and the semantic ranking.
    case hybrid
}

/// One hybrid search result.
struct SemanticSearchResult: Equatable {
    var clipID: Int64
    var score: Double
    var matchedIn: SearchMatchSource
}

/// A text clip offered for semantic indexing.
struct SemanticCandidate: Equatable {
    var id: Int64
    var text: String
    /// Callers set this from `SensitiveContent.isSensitive(clip:)`.
    var isSensitive: Bool
}

/// Reports whether the embedding model assets are on disk. Injected so tests
/// and previews never touch the OS model store.
protocol SemanticAssetProbe {
    /// True when embeddings can be computed without a download.
    var hasAvailableAssets: Bool { get }
}

/// Pure availability decision for semantic search.
enum SemanticAvailability: Equatable {
    case ready
    case disabledByUser
    case assetsMissing

    /// Opt-in first, then assets: a download is never implied by being enabled.
    static func evaluate(isEnabled: Bool, probe: SemanticAssetProbe) -> SemanticAvailability {
        guard isEnabled else { return .disabledByUser }
        return probe.hasAvailableAssets ? .ready : .assetsMissing
    }
}

/// Snapshot of background indexing progress.
struct SemanticIndexProgress: Equatable {
    var indexed = 0
    var total = 0
    var isRunning = false
    var fraction: Double { total == 0 ? 1 : min(1, Double(indexed) / Double(total)) }
}

/// Hybrid semantic + keyword search (FEAT-15). Vectors live in the shared
/// `EmbeddingCache`; sensitive clips are never embedded; the query vector is
/// cached in a small LRU. Everything runs on this Mac.
///
/// `@unchecked Sendable`: the query cache, progress and cancel flag are only touched under
/// `lock`; `onProgress` is assigned once at wiring time, before indexing starts.
final class SemanticSearch: @unchecked Sendable {
    /// Newest text clips considered.
    static let candidateCap = 2000
    /// Minimum cosine similarity for a semantic hit.
    static let similarityFloor: Float = 0.25
    private static let queryCacheSize = 32

    private let embedder: TextEmbedder
    private let cache: EmbeddingCache
    private let lock = NSLock()
    private var queryCache: [(text: String, vector: LanguageVector)] = []
    private var progressValue = SemanticIndexProgress()
    private var cancelFlag = false

    /// Called on an arbitrary queue when progress changes.
    var onProgress: ((SemanticIndexProgress) -> Void)?

    init(embedder: TextEmbedder, cache: EmbeddingCache) {
        self.embedder = embedder
        self.cache = cache
    }

    /// Latest progress snapshot.
    var progress: SemanticIndexProgress {
        lock.lock(); defer { lock.unlock() }
        return progressValue
    }

    /// Stops a running `index` after the current clip.
    func cancelIndexing() {
        lock.lock(); cancelFlag = true; lock.unlock()
    }

    /// Keeps the newest `candidateCap` non-sensitive, non-empty candidates.
    /// `candidates` must be newest first.
    static func eligible(_ candidates: [SemanticCandidate]) -> [SemanticCandidate] {
        Array(candidates.lazy.filter { !$0.isSensitive && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(candidateCap))
    }

    /// Embeds every eligible candidate missing from the cache, reporting progress.
    /// Blocking; call from a background queue.
    func index(_ candidates: [SemanticCandidate]) {
        let work = Self.eligible(candidates)
        lock.lock(); cancelFlag = false; lock.unlock()
        publish(SemanticIndexProgress(indexed: 0, total: work.count, isRunning: true))
        for (offset, item) in work.enumerated() {
            lock.lock(); let stop = cancelFlag; lock.unlock()
            if stop { break }
            let hash = StableHash.fnv1a(item.text)
            if cache.lookup(id: item.id, textHash: hash) == nil, let vector = embedder.embedding(for: item.text) {
                cache.store(id: item.id, textHash: hash, value: vector)
            }
            if offset % 25 == 0 || offset == work.count - 1 {
                publish(SemanticIndexProgress(indexed: offset + 1, total: work.count, isRunning: true))
            }
        }
        cache.flush()
        var done = progress
        done.isRunning = false
        publish(done)
    }

    /// Ranks eligible cached clips by cosine similarity to `query` (best first).
    func semanticRanking(query: String, candidates: [SemanticCandidate]) -> [Int64] {
        guard let queryVector = queryEmbedding(query) else { return [] }
        var scored: [(id: Int64, score: Float)] = []
        for item in Self.eligible(candidates) {
            guard let stored = cache.lookup(id: item.id, textHash: StableHash.fnv1a(item.text)),
                stored.language == queryVector.language
            else { continue }
            let score = VectorMath.cosine(queryVector.vector, stored.vector)
            if score >= Self.similarityFloor { scored.append((item.id, score)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.map(\.id)
    }

    /// Search-pipeline hook: fuses the keyword ranking with the semantic one.
    /// Returns `[]` semantic-wise unless `availability == .ready`, so the caller
    /// can always show `ftsRankedIDs` on its own. Keyword-only hits are tagged
    /// `.fullText`, semantic-only `.semantic`, both `.hybrid`.
    func hybridSearch(
        query: String, ftsRankedIDs: [Int64], candidates: [SemanticCandidate],
        availability: SemanticAvailability, limit: Int = 100
    ) -> [SemanticSearchResult] {
        let semantic = availability == .ready ? semanticRanking(query: query, candidates: candidates) : []
        let fused = RankFusion.fuse(
            [RankedList(ids: ftsRankedIDs, weight: 1), RankedList(ids: semantic, weight: 0.8)], limit: limit)
        return fused.map { entry in
            let source: SearchMatchSource =
                entry.listIndices.count > 1 ? .hybrid : (entry.listIndices == [1] ? .semantic : .fullText)
            return SemanticSearchResult(clipID: entry.id, score: entry.score, matchedIn: source)
        }
    }

    // MARK: Private

    private func queryEmbedding(_ query: String) -> LanguageVector? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        lock.lock()
        if let hit = queryCache.first(where: { $0.text == text }) { lock.unlock(); return hit.vector }
        lock.unlock()
        guard let vector = embedder.embedding(for: text) else { return nil }
        lock.lock()
        queryCache.append((text, vector))
        if queryCache.count > Self.queryCacheSize { queryCache.removeFirst() }
        lock.unlock()
        return vector
    }

    private func publish(_ value: SemanticIndexProgress) {
        lock.lock(); progressValue = value; lock.unlock()
        onProgress?(value)
    }
}

/// Small vector helpers shared by semantic search and auto-filing.
enum VectorMath {
    /// Cosine similarity; 0 for mismatched or zero vectors.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0, lhsNorm: Float = 0, rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denom = (lhsNorm * rhsNorm).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Element-wise mean; nil for empty input or mismatched dimensions.
    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in vector.indices { sum[index] += vector[index] } }
        return sum.map { $0 / Float(vectors.count) }
    }
}
