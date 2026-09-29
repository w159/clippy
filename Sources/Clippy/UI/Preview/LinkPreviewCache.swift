import Foundation

/// Metadata fetched for a link. Only title and site host: no page content is kept.
struct LinkPreviewMetadata: Codable, Equatable {
    var url: String
    var title: String?
    var host: String
    var iconPNG: Data?
    var fetchedAt: Date
}

/// Disk cache of link metadata in the Caches directory, capped by total bytes and age.
/// The clock and directory are injected so eviction is testable.
final class LinkPreviewCache {
    private let directory: URL
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let now: () -> Date
    private let fileManager = FileManager.default

    /// Default location: `~/Library/Caches/<bundle>/LinkPreviews` (never synced or backed up).
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Clippy", isDirectory: true).appendingPathComponent("LinkPreviews", isDirectory: true)
    }

    /// Creates a cache; `maxBytes` defaults to 5 MB, `maxAge` to 7 days.
    init(directory: URL = LinkPreviewCache.defaultDirectory(), maxBytes: Int = 5_000_000,
         maxAge: TimeInterval = 7 * 86_400, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        self.now = now
    }

    /// Cached entry for the URL, nil when missing or expired (expired files are removed).
    func entry(for url: URL) -> LinkPreviewMetadata? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file),
              let meta = try? JSONDecoder().decode(LinkPreviewMetadata.self, from: data) else { return nil }
        if now().timeIntervalSince(meta.fetchedAt) > maxAge {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return meta
    }

    /// Stores the entry, then evicts oldest entries until under the byte cap.
    func store(_ meta: LinkPreviewMetadata, for url: URL) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(meta) else { return }
        let file = fileURL(for: url)
        try? data.write(to: file, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        evict()
    }

    /// Removes oldest entries (by `fetchedAt`) until the total size is within the cap.
    func evict() {
        var items: [(url: URL, date: Date, size: Int)] = files().compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let meta = try? JSONDecoder().decode(LinkPreviewMetadata.self, from: data) else {
                try? fileManager.removeItem(at: file)
                return nil
            }
            return (file, meta.fetchedAt, data.count)
        }
        var total = items.reduce(0) { $0 + $1.size }
        items.sort { $0.date < $1.date }
        while total > maxBytes, let oldest = items.first {
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.size
            items.removeFirst()
        }
    }

    /// Deletes every cached entry.
    func clear() { try? fileManager.removeItem(at: directory) }

    /// Number of cached entries.
    var count: Int { files().count }

    /// Total bytes on disk.
    var totalBytes: Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func files() -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    private func fileURL(for url: URL) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }
}
