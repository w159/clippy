import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// A clip as the suggester sees it. `isSensitive` comes from
/// `SensitiveContent.isSensitive(clip:)`; sensitive clips are never embedded.
struct AutoFileClip: Equatable {
    var id: Int64
    var contentKey: String
    var text: String
    var isSensitive: Bool
}

/// A category as the suggester sees it.
struct AutoFileCategory: Equatable {
    var id: Int64
    var name: String
}

/// Read access the integrator adapts from `ClipDatabase`.
protocol AutoFileDataSource {
    func categories() -> [AutoFileCategory]
    /// Filed text clips of a category (any order, capped by the source).
    func filedClips(inCategory id: Int64) -> [AutoFileClip]
    /// Newest text clips that belong to no category.
    func recentUncategorized(limit: Int) -> [AutoFileClip]
}

/// Optional on-device refinement: picks one of the offered categories.
protocol AutoFileRefiner {
    /// Returns a category id from `options`, or nil for no opinion.
    func choose(preview: String, options: [AutoFileCategory]) async -> Int64?
}

/// Suggests existing categories for uncategorized clips from category centroids.
/// Suggestions are never applied here: `accept` calls the supplied filing sink.
final class AutoFileSuggester {
    private let embedder: TextEmbedder
    private let source: AutoFileDataSource
    private let dismissals: AutoFileDismissals
    private let preferences: SemanticSearchPreferences
    private let lock = NSLock()
    private var cached: [CategoryCentroid] = []

    init(
        embedder: TextEmbedder, source: AutoFileDataSource, dismissals: AutoFileDismissals = .shared,
        preferences: SemanticSearchPreferences = .standard
    ) {
        self.embedder = embedder
        self.source = source
        self.dismissals = dismissals
        self.preferences = preferences
    }

    /// Recomputes centroids from filed, non-sensitive clips. Blocking.
    func rebuildCentroids() {
        var members: [Int64: [LanguageVector]] = [:]
        for category in source.categories() {
            let vectors = source.filedClips(inCategory: category.id)
                .filter { !$0.isSensitive }
                .compactMap { embedder.embedding(for: $0.text) }
            if !vectors.isEmpty { members[category.id] = vectors }
        }
        let built = AutoFileScoring.centroids(members: members)
        lock.lock(); cached = built; lock.unlock()
    }

    /// Best suggestion for one clip, or nil (sensitive, dismissed, below floor).
    func suggest(for clip: AutoFileClip) -> AutoFileSuggestion? { top(for: clip, count: 1).first }

    /// Suggestions for the newest uncategorized clips; no-op while auto-file is off.
    func suggestForRecentUncategorized(limit: Int) -> [AutoFileSuggestion] {
        guard preferences.isAutoFileEnabled, limit > 0 else { return [] }
        lock.lock(); let empty = cached.isEmpty; lock.unlock()
        if empty { rebuildCentroids() }
        return source.recentUncategorized(limit: limit).compactMap { suggest(for: $0) }
    }

    /// Optionally lets `refiner` choose among the top three candidates. Falls
    /// back to the centroid winner unless refinement is on and returns a valid pick.
    func refine(_ clip: AutoFileClip, using refiner: AutoFileRefiner?) async -> AutoFileSuggestion? {
        let options = top(for: clip, count: 3)
        guard let first = options.first else { return nil }
        guard preferences.isFoundationRefinementEnabled, let refiner, options.count > 1, !clip.isSensitive else { return first }
        let names = source.categories()
        let offered = options.compactMap { option in names.first { $0.id == option.categoryID } }
        let preview = String(clip.text.prefix(200))
        guard let pick = await refiner.choose(preview: preview, options: offered),
            let chosen = options.first(where: { $0.categoryID == pick })
        else { return first }
        return chosen
    }

    /// Files the clip through `sink` after the user accepted. Never called implicitly.
    func accept(_ suggestion: AutoFileSuggestion, file sink: (_ clipID: Int64, _ categoryID: Int64) -> Void) {
        sink(suggestion.clipID, suggestion.categoryID)
    }

    /// Remembers the rejection so this pair is not suggested again.
    func dismiss(_ suggestion: AutoFileSuggestion, contentKey: String) {
        dismissals.dismiss(contentKey: contentKey, categoryID: suggestion.categoryID)
    }

    private func top(for clip: AutoFileClip, count: Int) -> [AutoFileSuggestion] {
        guard !clip.isSensitive, let vector = embedder.embedding(for: clip.text) else { return [] }
        lock.lock(); let centroids = cached; lock.unlock()
        let names = Dictionary(source.categories().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let skip = dismissals.dismissedCategories(contentKey: clip.contentKey)
        return AutoFileScoring.ranked(vector, against: centroids, excluding: skip).prefix(count).compactMap { hit in
            guard let name = names[hit.categoryID] else { return nil }
            let members = centroids.first { $0.categoryID == hit.categoryID }?.memberCount ?? 0
            return AutoFileSuggestion(
                clipID: clip.id, categoryID: hit.categoryID, score: hit.score,
                reason: "Similar to \(members) clips in \(name)")
        }
    }
}

#if canImport(FoundationModels)
    /// On-device Foundation Models refiner, gated like `FoundationModelsSecondStage`
    /// (`SystemLanguageModel.default.availability == .available`). Sends only a
    /// 200-character preview and category names, and only on this Mac.
    struct FoundationModelsAutoFileRefiner: AutoFileRefiner {
        func choose(preview: String, options: [AutoFileCategory]) async -> Int64? {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let list = options.map { "[\($0.id)] \($0.name)" }.joined(separator: "\n")
            let prompt = "Clip: \(preview)\nCategories:\n\(list)\nAnswer with the single best category id, digits only."
            let session = LanguageModelSession(instructions: "You file clipboard items into categories.")
            guard let response = try? await session.respond(to: prompt) else { return nil }
            let digits = response.content.filter(\.isNumber)
            return Int64(digits).flatMap { id in options.contains { $0.id == id } ? id : nil }
        }
    }
#endif
