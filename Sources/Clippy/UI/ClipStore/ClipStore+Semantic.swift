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

/// What the semantic pass reads: the opt-in, the asset probe and the engine.
/// `standard` is the shipped on-device engine; tests substitute their own.
struct SemanticSearchEnvironment: Sendable {
    var isEnabled: @Sendable () -> Bool
    var availability: @Sendable () -> SemanticAvailability
    var engine: @Sendable () -> SemanticSearch

    static let standard = SemanticSearchEnvironment(
        isEnabled: { SemanticSearchPreferences.standard.isEnabled },
        availability: {
            SemanticAvailability.evaluate(isEnabled: true, probe: SemanticSearchService.embedder)
        },
        engine: { SemanticSearchService.engine })
}

extension ClipStore {
    /// Second search pass: fuses the keyword hits with the semantic ranking and republishes if this search is still current.
    /// Free-text queries only, and only with the opt-in on; sensitive clips are never embedded (`SemanticCandidate.isSensitive`).
    /// Only the newest call runs to completion: it cancels the previous merge, and a merge that was already past
    /// its cancel checks is dropped by its run id.
    func scheduleSemanticMerge(query: String, token: Int, keyword: [Clip]) {
        semanticTask?.cancel()
        semanticTask = nil
        let environment = semanticEnvironment
        guard SemanticSearchGate.shouldRun(query: query, optedIn: environment.isEnabled()) else { return }
        semanticRunID &+= 1
        let runID = semanticRunID
        let database = self.database
        let limit = displayLimit
        semanticTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            var fused: (clips: [Clip], sources: [Int64: SearchMatchSource])?
            var readFailed = false
            if environment.availability() == .ready {
                let recent: [Clip]
                do {
                    recent = try Self.recentTextCandidates(from: database.dbQueue)
                } catch {
                    ClippyLog.error("Semantic candidate read failed: \(error)", category: ClippyLog.storage)
                    readFailed = true
                    recent = []
                }
                guard !Task.isCancelled else { return }
                let candidates = recent.compactMap { clip in
                    clip.id.map { SemanticCandidate(id: $0, text: clip.contentText, isSensitive: SensitiveContent.isSensitive(clip: clip)) }
                }
                let engine = environment.engine()
                engine.index(candidates)
                guard !Task.isCancelled else { return }
                let results = engine.hybridSearch(query: query, ftsRankedIDs: keyword.compactMap(\.id), candidates: candidates,
                                                  availability: .ready, limit: limit)
                let known = Set(keyword.compactMap(\.id))
                let missing = results.map(\.clipID).filter { !known.contains($0) }
                let pool = Self.fullClips(database, ids: missing)
                let merged = SemanticSearchGate.merge(results, keyword: keyword, pool: pool)
                if !merged.isEmpty {
                    fused = (merged, Dictionary(results.map { ($0.clipID, $0.matchedIn) }, uniquingKeysWith: { first, _ in first }))
                }
            }
            guard !Task.isCancelled else { return }
            let outcome = fused
            let failed = readFailed
            await MainActor.run { [weak self] in
                self?.finishSemanticMerge(runID: runID, token: token, query: query, keyword: keyword, fused: outcome)
                if failed { self?.reportSemanticFailure(token: token) }
            }
        }
    }

    /// Publishes a finished merge if it is still the newest one for the current search. Without a fused
    /// result (assets missing, nothing found) the keyword hits are shown, covering a list that was held
    /// back while the merge ran.
    private func finishSemanticMerge(runID: Int, token: Int, query: String, keyword: [Clip],
                                     fused: (clips: [Clip], sources: [Int64: SearchMatchSource])?) {
        guard runID == semanticRunID, refilterToken == token else { return }
        semanticCompletedRunID = runID
        if let fused {
            fusedQuery = query
            publishResults(fused.clips, matches: fused.sources)
        } else {
            fusedQuery = nil
            publishResults(keyword, matches: [:])
        }
    }

    /// Newest text clips, the semantic candidate pool. The rich-text blobs of up to 2000 rows are selected as
    /// NULL (every other Clip column stays, so the record decodes as usual); embedding and the sensitivity
    /// scan read only the text. Synchronous so it can run inside a detached task.
    /// Throws on a failed read so it never passes for "no clips".
    nonisolated static func recentTextCandidates(from reader: DatabaseReader) throws -> [Clip] {
        try reader.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT id, contentText, NULL AS contentRTF, NULL AS contentHTML, typeIdentifier, sourceAppBundleID,
                       sourceAppName, createdAt, contentKind, mediaFilename, thumbFilename, pixelWidth, pixelHeight,
                       byteSize, userTitle, filePath, ocrText
                FROM clips WHERE contentKind = ? ORDER BY createdAt DESC, id DESC LIMIT ?
                """, arguments: [ClipContentKind.text.rawValue, SemanticSearch.candidateCap])
        }
    }

    /// Publishes a failed semantic read on `searchError` (banner with Retry) when `token` is still the current search.
    func reportSemanticFailure(token: Int) {
        guard refilterToken == token else { return }
        searchError = "Couldn't finish the smart search. Try again."
    }

    /// Full rows for the semantic-only hits, which are shown and so need every field.
    private nonisolated static func fullClips(_ database: ClipDatabase, ids: [Int64]) -> [Int64: Clip] {
        guard !ids.isEmpty else { return [:] }
        let rows = (try? database.dbQueue.read { db in try Clip.fetchAll(db, keys: ids) }) ?? []
        return Dictionary(rows.compactMap { clip in clip.id.map { ($0, clip) } }, uniquingKeysWith: { first, _ in first })
    }
}
