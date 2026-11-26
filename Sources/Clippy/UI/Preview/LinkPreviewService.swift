import Foundation
import LinkPresentation
import AppKit

/// Fetches link metadata. Injected so tests never touch the network.
protocol LinkMetadataFetching: Sendable {
    /// Returns metadata for the URL or throws; must honour `timeout`.
    func fetch(_ url: URL, timeout: TimeInterval) async throws -> LinkPreviewMetadata
}

/// Production fetcher backed by `LPMetadataProvider`. NETWORK: sends the URL to its host.
struct LPLinkMetadataFetcher: LinkMetadataFetching {
    // Main-actor isolated: `LPMetadataProvider` is created and driven from the main thread.
    @MainActor
    func fetch(_ url: URL, timeout: TimeInterval) async throws -> LinkPreviewMetadata {
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        let meta = try await provider.startFetchingMetadata(for: url)
        var png: Data?
        if let icon = meta.iconProvider {
            png = await withCheckedContinuation { continuation in
                _ = icon.loadObject(ofClass: NSImage.self) { object, _ in
                    let tiff = (object as? NSImage)?.tiffRepresentation
                    continuation.resume(returning: tiff.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
                }
            }
        }
        return LinkPreviewMetadata(url: url.absoluteString, title: meta.title, host: url.host ?? "", iconPNG: png,
                                   fetchedAt: Date())
    }
}

/// Gatekeeper + cache in front of a fetcher. Order: opt-in, sensitivity, URL sanitising, host policy, cache, fetch.
@MainActor
final class LinkPreviewService {
    /// Seconds before a fetch is abandoned.
    static let timeout: TimeInterval = 5
    /// Process-wide instance using the real fetcher and preferences.
    static let shared = LinkPreviewService()

    private let fetcher: LinkMetadataFetching
    private let cache: LinkPreviewCache
    private let isEnabled: () -> Bool
    private let allow: () -> [String]
    private let deny: () -> [String]

    /// Creates a service; every dependency is injectable.
    init(fetcher: LinkMetadataFetching = LPLinkMetadataFetcher(), cache: LinkPreviewCache = LinkPreviewCache(),
         isEnabled: @escaping () -> Bool = { LinkPreviewPreferences.isEnabled },
         allow: @escaping () -> [String] = { LinkPreviewPreferences.allowHosts },
         deny: @escaping () -> [String] = { LinkPreviewPreferences.denyHosts }) {
        self.fetcher = fetcher
        self.cache = cache
        self.isEnabled = isEnabled
        self.allow = allow
        self.deny = deny
    }

    /// Metadata for the link, or nil when disabled, sensitive, unsafe, denied or the fetch failed.
    func metadata(for url: URL, sensitive: Bool) async -> LinkPreviewMetadata? {
        guard isEnabled(), !sensitive, let clean = LinkURLSanitizer.sanitized(url), let host = clean.host,
              LinkPreviewPreferences.isHostAllowed(host, allow: allow(), deny: deny()) else { return nil }
        if let cached = cache.entry(for: clean) { return cached }
        guard let fetched = try? await fetcher.fetch(clean, timeout: Self.timeout) else { return nil }
        cache.store(fetched, for: clean)
        return fetched
    }

    /// Deletes the on-disk cache.
    func clearCache() { cache.clear() }

    /// Cache size in bytes.
    var cacheBytes: Int { cache.totalBytes }
}
