import Foundation

/// Shared on-device auto-file suggester (FEAT-16). Centroids are cached and rebuilt at most every few minutes.
final class AutoFileService: @unchecked Sendable {
    /// Process-wide instance.
    static let shared = AutoFileService()

    private static let rebuildInterval: TimeInterval = 300
    private let lock = NSLock()
    private var suggester: AutoFileSuggester?
    private var databasePath: String?
    private var lastRebuild = Date.distantPast

    /// Best category suggestion for `clip`; nil for sensitive clips, dismissed pairs, below-floor scores or missing model assets.
    /// `force` skips the auto-file opt-in for an explicit "Suggest Category" request.
    func suggestion(for clip: AutoFileClip, database: ClipDatabase, force: Bool) async -> AutoFileSuggestion? {
        guard force || SemanticSearchPreferences.standard.isAutoFileEnabled, !clip.isSensitive else { return nil }
        return await Task.detached(priority: .utility) { [self] in
            guard SemanticSearchService.embedder.hasAvailableAssets else { return nil }
            return prepared(for: database).suggest(for: clip)
        }.value
    }

    /// Records a dismissal so the pair is not suggested again.
    func dismiss(_ suggestion: AutoFileSuggestion, contentKey: String) {
        lock.lock(); let current = suggester; lock.unlock()
        current?.dismiss(suggestion, contentKey: contentKey)
    }

    private func prepared(for database: ClipDatabase) -> AutoFileSuggester {
        lock.lock(); defer { lock.unlock() }
        let path = database.databaseURL.path
        if suggester == nil || databasePath != path {
            suggester = AutoFileSuggester(embedder: SemanticSearchService.embedder, source: ClipDatabaseAutoFileSource(database: database))
            databasePath = path
            lastRebuild = .distantPast
        }
        if Date().timeIntervalSince(lastRebuild) > Self.rebuildInterval {
            suggester?.rebuildCentroids()
            lastRebuild = Date()
        }
        return suggester!
    }
}
