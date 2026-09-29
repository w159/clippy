import Foundation
import GRDB

/// Process-wide on-device semantic search engine (FEAT-15). Nothing here runs
/// unless the user opted in and the embedding assets are already on disk.
enum SemanticSearchService {
    /// Embedder doubling as the asset probe.
    static let embedder = NLContextualTextEmbedder()
    /// Shared engine backed by the persistent embedding cache.
    static let engine = SemanticSearch(
        embedder: embedder,
        cache: EmbeddingCache(fileURL: EmbeddingCache.defaultFileURL, revision: embedder.revision))
}

/// Pure gating for the semantic merge.
enum SemanticSearchGate {
    /// True only for a plain free-text query (no phrases, operators, filters or negations).
    static func isFreeText(_ query: String) -> Bool {
        let parsed = ClipQueryParser.parse(query)
        return !parsed.text.trimmingCharacters(in: .whitespaces).isEmpty
            && parsed.phrases.isEmpty && parsed.sourceApps.isEmpty && parsed.since == nil && parsed.until == nil
            && parsed.kinds.isEmpty && parsed.excludedTerms.isEmpty && parsed.excludedPhrases.isEmpty
            && parsed.excludedKinds.isEmpty && parsed.excludedApps.isEmpty && parsed.categories.isEmpty
            && parsed.excludedCategories.isEmpty && parsed.sizeConstraints.isEmpty
    }

    /// True when the semantic pass may run for `query` at all.
    static func shouldRun(query: String, optedIn: Bool) -> Bool { optedIn && isFreeText(query) }

    /// Orders fused results into clips: keyword clips keep their objects, semantic-only ids resolve through `pool`.
    static func merge(_ results: [SemanticSearchResult], keyword: [Clip], pool: [Int64: Clip]) -> [Clip] {
        let known = Dictionary(keyword.compactMap { clip in clip.id.map { ($0, clip) } }, uniquingKeysWith: { first, _ in first })
        return results.compactMap { known[$0.clipID] ?? pool[$0.clipID] }
    }
}

extension ClipStore {
    /// Second search pass: fuses the keyword hits with the semantic ranking and republishes if this search is still current.
    /// Free-text queries only, and only with the opt-in on; sensitive clips are never embedded (`SemanticCandidate.isSensitive`).
    func scheduleSemanticMerge(query: String, token: Int, keyword: [Clip]) {
        semanticMatches = [:]
        let preferences = SemanticSearchPreferences.standard
        guard SemanticSearchGate.shouldRun(query: query, optedIn: preferences.isEnabled) else { return }
        let database = self.database
        let limit = displayLimit
        Task.detached(priority: .utility) { [weak self] in
            let availability = SemanticAvailability.evaluate(isEnabled: true, probe: SemanticSearchService.embedder)
            guard availability == .ready, !Task.isCancelled else { return }
            let recent = Self.recentTextClips(database)
            let candidates = recent.compactMap { clip in
                clip.id.map { SemanticCandidate(id: $0, text: clip.contentText, isSensitive: SensitiveContent.isSensitive(clip: clip)) }
            }
            let engine = SemanticSearchService.engine
            engine.index(candidates)
            let results = engine.hybridSearch(query: query, ftsRankedIDs: keyword.compactMap(\.id), candidates: candidates,
                                              availability: availability, limit: limit)
            let pool = Dictionary(recent.compactMap { clip in clip.id.map { ($0, clip) } }, uniquingKeysWith: { first, _ in first })
            let merged = SemanticSearchGate.merge(results, keyword: keyword, pool: pool)
            guard !Task.isCancelled, !merged.isEmpty else { return }
            let sources = Dictionary(results.map { ($0.clipID, $0.matchedIn) }, uniquingKeysWith: { first, _ in first })
            await MainActor.run { [weak self] in
                guard let self, self.refilterToken == token else { return }
                self.semanticMatches = sources
                self.clips = merged
            }
        }
    }

    /// Newest text clips, the semantic candidate pool. Synchronous so it can run inside a detached task.
    private nonisolated static func recentTextClips(_ database: ClipDatabase) -> [Clip] {
        (try? database.dbQueue.read { db in
            try Clip.fetchAll(db, sql: "SELECT * FROM clips WHERE contentKind = ? ORDER BY createdAt DESC, id DESC LIMIT ?",
                              arguments: [ClipContentKind.text.rawValue, SemanticSearch.candidateCap])
        }) ?? []
    }
}
