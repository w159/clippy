import Foundation

/// Point-in-time view of the feedback store, cheap to consult per candidate.
struct DismissalSnapshot {
    var neverKeys: Set<String> = []
    var demotedKeys: Set<String> = []
    var excludedApps: Set<String> = []

    var isEmpty: Bool { neverKeys.isEmpty && demotedKeys.isEmpty && excludedApps.isEmpty }
}

/// Persistent suggestion feedback (ROADMAP INT-07). Clips are identified by
/// their content hash (`Clip.contentKey`, SHA-256), NOT their row id, so the
/// mark survives a re-copy and no clip text is ever stored here.
///
/// - `markNotRelevant`: down-weights the clip (by `SuggestionTuning.notRelevantWeight`) for N days.
/// - `neverSuggest`: the clip is never suggested until restored.
/// - `excludeApp`: no suggestions are produced while that app (bundle id) is frontmost.
///
/// JSON in Application Support, atomic writes. A missing or corrupt file is an
/// empty store. Thread-safe.
///
/// `@unchecked Sendable`: `loaded` and `stored` are only read or written under `lock`.
final class SuggestionDismissals: @unchecked Sendable {
    static let shared = SuggestionDismissals(fileURL: defaultFileURL)

    /// Kind of feedback recorded for a clip.
    enum Kind: String, Codable { case notRelevant, never }

    /// One clip-level dismissal, listed for management UI.
    struct Entry: Codable, Equatable {
        var contentKey: String
        var kind: Kind
        /// Expiry of a `notRelevant` mark; nil for `never`.
        var until: Date?
    }

    private struct Stored: Codable {
        var version = 1
        var clips: [Entry] = []
        var apps: [String] = []
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
            .appendingPathComponent("suggestion-dismissals.json")
    }

    /// Cap on stored entries so the file cannot grow without bound.
    private static let maxEntries = 5000

    private let fileURL: URL?
    private let lock = NSLock()
    private var loaded = false
    private var stored = Stored()

    /// `nil` keeps the store in memory only (tests).
    init(fileURL: URL?) { self.fileURL = fileURL }

    // MARK: Mutation

    /// Down-weights `clip` for `days` days from `now`. A `never` mark wins and is kept.
    func markNotRelevant(
        _ clip: Clip, days: Int = SuggestionTuning.notRelevantDays, now: Date = Date()
    ) {
        markNotRelevant(contentKey: clip.contentKey, days: days, now: now)
    }

    func markNotRelevant(contentKey: String, days: Int, now: Date = Date()) {
        mutate { stored in
            if stored.clips.contains(where: { $0.contentKey == contentKey && $0.kind == .never }) { return }
            let until = now.addingTimeInterval(TimeInterval(max(1, days)) * 86_400)
            stored.clips.removeAll { $0.contentKey == contentKey }
            stored.clips.append(Entry(contentKey: contentKey, kind: .notRelevant, until: until))
        }
    }

    /// "Never suggest this clip."
    func neverSuggest(_ clip: Clip) { neverSuggest(contentKey: clip.contentKey) }

    func neverSuggest(contentKey: String) {
        mutate { stored in
            stored.clips.removeAll { $0.contentKey == contentKey }
            stored.clips.append(Entry(contentKey: contentKey, kind: .never, until: nil))
        }
    }

    /// Removes any clip-level mark (undo).
    func restore(contentKey: String) {
        mutate { $0.clips.removeAll { $0.contentKey == contentKey } }
    }

    func excludeApp(_ bundleID: String) {
        mutate { if !$0.apps.contains(bundleID) { $0.apps.append(bundleID) } }
    }

    func includeApp(_ bundleID: String) {
        mutate { $0.apps.removeAll { $0 == bundleID } }
    }

    // MARK: Queries

    /// Clip-level entries, newest marks last. Expired `notRelevant` marks are omitted.
    func entries(now: Date = Date()) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return stored.clips.filter { isActive($0, now: now) }
    }

    /// Bundle ids excluded from suggestions, sorted.
    func excludedApps() -> [String] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return stored.apps.sorted()
    }

    /// Everything the ranker needs, taken under one lock.
    func snapshot(now: Date = Date()) -> DismissalSnapshot {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var snapshot = DismissalSnapshot(excludedApps: Set(stored.apps))
        for entry in stored.clips where isActive(entry, now: now) {
            switch entry.kind {
            case .never: snapshot.neverKeys.insert(entry.contentKey)
            case .notRelevant: snapshot.demotedKeys.insert(entry.contentKey)
            }
        }
        return snapshot
    }

    // MARK: Internals

    private func isActive(_ entry: Entry, now: Date) -> Bool {
        guard entry.kind == .notRelevant else { return true }
        return (entry.until ?? .distantPast) > now
    }

    private func mutate(_ change: (inout Stored) -> Void) {
        lock.lock()
        loadIfNeeded()
        change(&stored)
        if stored.clips.count > Self.maxEntries {
            stored.clips.removeFirst(stored.clips.count - Self.maxEntries)
        }
        let data = fileURL == nil ? nil : try? JSONEncoder().encode(stored)
        lock.unlock()
        if let data { write(data) }
    }

    /// Caller holds `lock`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(Stored.self, from: data), decoded.version == 1
        else { return }
        stored = decoded
    }

    private func write(_ data: Data) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            ClippyLog.warning(
                "suggestion dismissals save failed: \(error.localizedDescription)",
                category: ClippyLog.storage)
        }
    }
}
