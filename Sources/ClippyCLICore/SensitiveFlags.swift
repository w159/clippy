import Foundation

/// Read-only view of the app's sensitive-flag sidecar
/// (`<support>/media/_sidecar/sensitive-flags.json`), mirroring the MCP server:
/// unreadable or malformed sidecar means every clip is withheld.
public struct SensitiveFlags: Equatable {
    struct Entry: Equatable {
        var confidence: Int
        var userOverride: Bool?
    }

    /// Only confidence `.medium` (1) and above counts (SensitiveContent.sensitiveThreshold).
    static let threshold = 1

    var unreadable: Bool
    var entries: [String: Entry]

    /// Builds flags directly (tests).
    public init(unreadable: Bool = false, entries: [String: (confidence: Int, userOverride: Bool?)] = [:]) {
        self.unreadable = unreadable
        self.entries = entries.mapValues { Entry(confidence: $0.confidence, userOverride: $0.userOverride) }
    }

    /// Sidecar path for a support directory.
    public static func sidecarURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("media/_sidecar/sensitive-flags.json")
    }

    /// Loads the sidecar; a missing file is "nothing flagged".
    public static func load(supportDirectory: URL) -> SensitiveFlags {
        let url = sidecarURL(supportDirectory: supportDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return SensitiveFlags() }
        guard let data = try? Data(contentsOf: url) else { return SensitiveFlags(unreadable: true) }
        return parse(data)
    }

    /// Parses sidecar bytes (`[contentKey: {confidence: Int, userOverride: Bool?}]`).
    public static func parse(_ data: Data) -> SensitiveFlags {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SensitiveFlags(unreadable: true)
        }
        var result = SensitiveFlags()
        for (key, value) in object {
            let dict = value as? [String: Any]
            result.entries[key] = Entry(confidence: dict?["confidence"] as? Int ?? 0,
                                        userOverride: dict?["userOverride"] as? Bool)
        }
        return result
    }

    /// True when the clip must be withheld. Override wins, then the recorded flag.
    public func isSensitive(contentKey: String) -> Bool {
        if unreadable { return true }
        guard let entry = entries[contentKey] else { return false }
        if let override = entry.userOverride { return override }
        return entry.confidence >= Self.threshold
    }
}
