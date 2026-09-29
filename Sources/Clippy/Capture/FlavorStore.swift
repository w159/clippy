import AppKit
import CryptoKit
import Foundation

/// Everything on a pasteboard that Clippy's columns do not already hold: the
/// extra representations (JPEG, PDF, RTFD, vCard, color, `public.url`...) of one
/// or more pasteboard items, captured up to a size budget (CAP-03).
struct PasteboardSnapshot: Equatable {
    struct Flavor: Equatable {
        let type: String
        let data: Data
    }

    struct Item: Equatable {
        /// The item's plain string. Recorded only for multi-item pasteboards; a
        /// single item's string is the clip's own `contentText`.
        var string: String?
        var flavors: [Flavor]
    }

    var items: [Item]

    /// Total bytes across all flavors.
    var byteCount: Int { items.reduce(0) { $0 + $1.flavors.reduce(0) { $0 + $1.data.count } } }
}

/// Reads flavors off a pasteboard.
enum PasteboardFlavors {

    /// Types never preserved as flavors: those held in Clippy's own columns,
    /// clipboard-manager markers, file references (handled by file clips), and
    /// dynamic/promise types that cannot be restored.
    private static let excludedExact: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text",
        "public.plain-text", "NSStringPboardType", "com.apple.traditional-mac-plain-text",
        "public.rtf", "NeXT Rich Text Format v1.0 pasteboard type", "public.html",
        "public.file-url", "NSFilenamesPboardType", "com.apple.finder.node",
    ]

    private static let excludedPrefixes = ["dyn.", "org.nspasteboard.", "com.apple.pasteboard."]

    static func isPreservable(_ type: String) -> Bool {
        !excludedExact.contains(type) && !excludedPrefixes.contains { type.hasPrefix($0) }
    }

    /// Snapshot of `pasteboard`'s extra flavors within `budget` bytes. A flavor
    /// that would push the total over budget is skipped, not truncated; later,
    /// smaller flavors may still fit. `excluding` drops types the caller already
    /// stores (the PNG of an image clip). Returns nil when there is nothing to
    /// preserve: a single item with no extra flavors.
    static func snapshot(from pasteboard: NSPasteboard, budget: Int, excluding: Set<String> = []) -> PasteboardSnapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty, budget > 0 else { return nil }
        var used = 0
        var items: [PasteboardSnapshot.Item] = []
        for pasteboardItem in pasteboardItems {
            var flavors: [PasteboardSnapshot.Flavor] = []
            for pbType in pasteboardItem.types {
                let type = pbType.rawValue
                guard isPreservable(type), !excluding.contains(type),
                      let data = pasteboardItem.data(forType: pbType), !data.isEmpty,
                      used + data.count <= budget
                else { continue }
                used += data.count
                flavors.append(.init(type: type, data: data))
            }
            let string = pasteboardItems.count > 1 ? pasteboardItem.string(forType: .string) : nil
            items.append(.init(string: string, flavors: flavors))
        }
        guard items.count > 1 || items.contains(where: { !$0.flavors.isEmpty }) else { return nil }
        return PasteboardSnapshot(items: items)
    }
}

/// Persists `PasteboardSnapshot`s as files in the media store's sidecar
/// directory: one JSON manifest per clip plus one blob per flavor, all keyed by
/// `Clip.contentKey`. No schema change; eviction of a clip leaves its sidecar
/// files until `prune(keepingKeys:)` runs.
///
/// `@unchecked Sendable`: immutable state; `FileManager.default` is documented thread-safe.
final class FlavorStore: @unchecked Sendable {
    private struct Manifest: Codable {
        struct Flavor: Codable {
            let type: String
            let file: String
        }
        struct Item: Codable {
            var string: String?
            var flavors: [Flavor]
        }
        var items: [Item]
    }

    private let directory: URL
    private let fileManager = FileManager.default

    /// `directory` is created if missing (use `MediaStore.sidecarDirectory`).
    init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func manifestURL(_ key: String) -> URL { directory.appendingPathComponent("flavors-\(key).json") }

    /// Writes `snapshot` for `key`, replacing any earlier one. Blob names are
    /// content hashes, so identical flavors across clips share a file.
    func write(_ snapshot: PasteboardSnapshot, key: String) throws {
        var manifest = Manifest(items: [])
        for item in snapshot.items {
            var entry = Manifest.Item(string: item.string, flavors: [])
            for flavor in item.flavors {
                let name = "flavor-" + SHA256.hash(data: flavor.data).map { String(format: "%02x", $0) }.joined() + ".bin"
                let url = directory.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: url.path) { try flavor.data.write(to: url, options: .atomic) }
                entry.flavors.append(.init(type: flavor.type, file: name))
            }
            manifest.items.append(entry)
        }
        try JSONEncoder().encode(manifest).write(to: manifestURL(key), options: .atomic)
    }

    /// The stored snapshot for `key`, or nil when none exists or any blob is
    /// missing (a partial restore would paste a subtly wrong clip).
    func restore(key: String) -> PasteboardSnapshot? {
        guard let data = try? Data(contentsOf: manifestURL(key)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        var items: [PasteboardSnapshot.Item] = []
        for entry in manifest.items {
            var flavors: [PasteboardSnapshot.Flavor] = []
            for flavor in entry.flavors {
                guard let blob = try? Data(contentsOf: directory.appendingPathComponent(flavor.file)) else { return nil }
                flavors.append(.init(type: flavor.type, data: blob))
            }
            items.append(.init(string: entry.string, flavors: flavors))
        }
        return PasteboardSnapshot(items: items)
    }

    func hasSnapshot(key: String) -> Bool { fileManager.fileExists(atPath: manifestURL(key).path) }

    func delete(key: String) {
        try? fileManager.removeItem(at: manifestURL(key))
    }

    /// Removes manifests whose clip no longer exists, then blobs no manifest
    /// references. Only files this store wrote (`flavors-*`, `flavor-*`) are touched.
    func prune(keepingKeys keep: Set<String>) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var referenced = Set<String>()
        for name in names where name.hasPrefix("flavors-") && name.hasSuffix(".json") {
            let key = String(name.dropFirst("flavors-".count).dropLast(".json".count))
            if keep.contains(key) {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                   let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                    manifest.items.forEach { $0.flavors.forEach { referenced.insert($0.file) } }
                }
            } else {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        for name in names where name.hasPrefix("flavor-") && !referenced.contains(name) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
