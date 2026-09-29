import Foundation
import os

/// Persists the "this clip is sensitive" flag without a schema change: a JSON
/// sidecar in the media store's sidecar directory, keyed by `Clip.contentKey`
/// (a hash of the content, never the content itself). Holds the detected kinds
/// and confidence recorded at capture, plus an optional explicit user override
/// ("mark as sensitive" / "not sensitive").
///
/// Thread-safe; writes are atomic. Mutations are rare (one per sensitive
/// capture), so the whole file is rewritten each time.
///
/// `@unchecked Sendable`: `entries` is only touched under `lock`; the rest is immutable.
final class SensitiveFlagStore: @unchecked Sendable {

    /// One flagged clip.
    struct Entry: Codable, Equatable {
        var kinds: [SensitiveContent.Kind]
        var confidence: SensitiveContent.Confidence
        var flaggedAt: Date
        /// nil = follow detection; true/false = the user's explicit choice.
        var userOverride: Bool?
    }

    static let fileName = "sensitive-flags.json"

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    /// The store the running app is using, registered by `ClipboardMonitor.start()`
    /// so `SensitiveContent.isSensitive(clip:)` needs no plumbing at call sites.
    private static let registered = OSAllocatedUnfairLock<SensitiveFlagStore?>(initialState: nil)
    static var current: SensitiveFlagStore? {
        registered.withLock { $0 }
    }

    static func register(_ store: SensitiveFlagStore?) {
        registered.withLock { $0 = store }
    }

    /// `directory` is created if missing (use `MediaStore.sidecarDirectory`).
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.iso.decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func entry(for key: String) -> Entry? {
        lock.withLock { entries[key] }
    }

    var count: Int { lock.withLock { entries.count } }

    /// Records the findings detected at capture. No-op when nothing reaches the
    /// sensitive threshold, and it never clobbers an explicit user override.
    func record(key: String, findings: [SensitiveContent.Finding]) {
        let strong = findings.filter { $0.confidence >= SensitiveContent.sensitiveThreshold }
        guard let top = strong.map(\.confidence).max() else { return }
        mutate {
            var entry = $0[key] ?? Entry(kinds: [], confidence: top, flaggedAt: Date(), userOverride: nil)
            entry.kinds = strong.map(\.kind)
            entry.confidence = top
            $0[key] = entry
        }
    }

    /// Sets the user's explicit choice. `nil` removes the override and falls
    /// back to detection.
    func setOverride(key: String, isSensitive: Bool?) {
        mutate {
            if var entry = $0[key] {
                entry.userOverride = isSensitive
                if isSensitive == nil, entry.kinds.isEmpty { $0[key] = nil } else { $0[key] = entry }
            } else if let isSensitive {
                $0[key] = Entry(kinds: [], confidence: .low, flaggedAt: Date(), userOverride: isSensitive)
            }
        }
    }

    /// Drops entries whose clip no longer exists.
    func prune(keepingKeys keep: Set<String>) {
        mutate { $0 = $0.filter { keep.contains($0.key) } }
    }

    private func mutate(_ body: (inout [String: Entry]) -> Void) {
        lock.withLock {
            let before = entries
            body(&entries)
            guard entries != before else { return }
            do {
                try JSONEncoder.iso.encode(entries).write(to: fileURL, options: .atomic)
            } catch {
                ClippyLog.error("Sensitive flag store write failed: \(error)", category: ClippyLog.storage)
            }
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
