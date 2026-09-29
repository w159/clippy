import Foundation

/// Remembers rejected (clip, category) pairs so a dismissed suggestion does not
/// return. Keyed by `Clip.contentKey` (SHA-256), never by clip text, like
/// `SuggestionDismissals`. Dismissing one category does not block others.
/// JSON in Application Support, atomic writes; `nil` URL is in-memory (tests).
///
/// `@unchecked Sendable`: `loaded` and `stored` are only touched under `lock`.
final class AutoFileDismissals: @unchecked Sendable {
    static let shared = AutoFileDismissals(fileURL: defaultFileURL)

    private struct Stored: Codable {
        var version = 1
        /// "contentKey|categoryID"
        var pairs: [String] = []
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
            .appendingPathComponent("autofile-dismissals.json")
    }

    private static let maxEntries = 5000

    private let fileURL: URL?
    private let lock = NSLock()
    private var loaded = false
    private var stored = Stored()

    init(fileURL: URL?) { self.fileURL = fileURL }

    /// Records that `categoryID` was rejected for the clip.
    func dismiss(contentKey: String, categoryID: Int64) {
        mutate { stored in
            let pair = Self.pair(contentKey, categoryID)
            guard !stored.pairs.contains(pair) else { return }
            stored.pairs.append(pair)
            if stored.pairs.count > Self.maxEntries { stored.pairs.removeFirst(stored.pairs.count - Self.maxEntries) }
        }
    }

    /// Forgets one rejection.
    func restore(contentKey: String, categoryID: Int64) {
        mutate { $0.pairs.removeAll { $0 == Self.pair(contentKey, categoryID) } }
    }

    /// Whether the pair was dismissed.
    func isDismissed(contentKey: String, categoryID: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return stored.pairs.contains(Self.pair(contentKey, categoryID))
    }

    /// Category ids dismissed for the clip.
    func dismissedCategories(contentKey: String) -> Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let prefix = contentKey + "|"
        return Set(stored.pairs.compactMap { $0.hasPrefix(prefix) ? Int64($0.dropFirst(prefix.count)) : nil })
    }

    /// Drops every stored dismissal.
    func clear() { mutate { $0.pairs.removeAll() } }

    private static func pair(_ key: String, _ categoryID: Int64) -> String { "\(key)|\(categoryID)" }

    private func mutate(_ change: (inout Stored) -> Void) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        change(&stored)
        save()
    }

    /// Caller holds `lock`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        stored = decoded
    }

    /// Caller holds `lock`.
    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
