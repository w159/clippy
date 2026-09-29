import Foundation

/// Applies retention rules (FEAT-10): per-kind and per-app TTLs, "forget after
/// N days", and auto-expiry of sensitive clips. Runs at launch and hourly.
///
/// Deletion goes through `ClipDatabase.deleteClip(id:)` (which also removes
/// media), and every run that deletes anything is audit-logged with clip ids
/// only, never content.
final class RetentionService {

    /// A clip that a rule would delete. Carries no clip content.
    struct Candidate: Equatable {
        var clipID: Int64
        var kind: ClipContentKind
        var sourceAppBundleID: String?
        var createdAt: Date
        var reason: RetentionReason
    }

    struct Result: Equatable {
        var deleted: [Int64]
        var failed: [Int64]
    }

    private let database: ClipDatabase
    private let preferences: RetentionPreferences
    private let audit: AuditLog
    private let now: () -> Date
    private let sensitive: (Clip) -> Bool
    private var timer: Timer?

    init(database: ClipDatabase,
         preferences: RetentionPreferences = RetentionPreferences(),
         audit: AuditLog = .shared,
         now: @escaping () -> Date = Date.init,
         isSensitive: @escaping (Clip) -> Bool = { SensitiveContent.isSensitive(clip: $0) }) {
        self.database = database
        self.preferences = preferences
        self.audit = audit
        self.now = now
        self.sensitive = isSensitive
    }

    // MARK: - Preview

    /// What `rules` would delete right now. Does not check `isEnabled`, so
    /// Settings can preview rules before turning them on. Pinned/categorized
    /// clips are skipped unless `rules.includeCategorized`.
    func preview(rules: RetentionRules) throws -> [Candidate] {
        let clips = try database.allClips()
        let categorized = rules.includeCategorized ? [:] : try database.membershipMap()
        let current = now()
        var out: [Candidate] = []
        for clip in clips {
            guard let id = clip.id else { continue }
            if !rules.includeCategorized, categorized[id]?.isEmpty == false { continue }
            // Only scan text when a sensitive rule could matter.
            let flagged = rules.sensitiveTTLHours != nil && sensitive(clip)
            guard let ttl = rules.ttl(kind: clip.contentKind, bundleID: clip.sourceAppBundleID, isSensitive: flagged)
            else { continue }
            if current.timeIntervalSince(clip.createdAt) >= ttl.seconds {
                out.append(Candidate(clipID: id, kind: clip.contentKind, sourceAppBundleID: clip.sourceAppBundleID,
                                     createdAt: clip.createdAt, reason: ttl.reason))
            }
        }
        return out
    }

    // MARK: - Apply

    /// Deletes what `rules` expire. No-op when rules are disabled.
    @discardableResult
    func apply(rules: RetentionRules, actor: String = "retention") throws -> Result {
        guard rules.isEnabled else { return Result(deleted: [], failed: []) }
        var deleted: [Int64] = [], failed: [Int64] = []
        for candidate in try preview(rules: rules) {
            do {
                try database.deleteClip(id: candidate.clipID)
                ClipSpotlightIndexer.remove(clipID: candidate.clipID)
                deleted.append(candidate.clipID)
            } catch {
                failed.append(candidate.clipID)
                ClippyLog.error("Retention delete failed: \(error)", category: ClippyLog.storage)
            }
        }
        if !deleted.isEmpty {
            audit.record(actor: actor, action: "retention.expire",
                         detail: "expired \(deleted.count) clip(s)", clipIDs: deleted)
        }
        return Result(deleted: deleted, failed: failed)
    }

    /// Applies the persisted rules.
    @discardableResult
    func applyPersistedRules() -> Result? {
        try? apply(rules: preferences.rules)
    }

    // MARK: - Scheduling

    /// Runs once now and then hourly. Idempotent.
    @MainActor
    func start() {
        guard timer == nil else { return }
        runInBackground()
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            self?.runInBackground()
        }
    }

    @MainActor
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func runInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.applyPersistedRules()
        }
    }
}
