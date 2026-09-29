import Foundation

// SET-05: parse and edit the Ignored Apps list. Storage stays an array of bundle IDs.

/// Bundle-id helpers for the Ignored Apps picker.
enum IgnoredAppsParser {
    /// A reverse-DNS id: at least two dot-separated labels of letters, digits, hyphens.
    static func isPlausibleBundleID(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            }
        }
    }

    /// Splits free text (newlines or commas) into valid ids (deduplicated, order kept) and rejects.
    static func parse(_ text: String) -> (valid: [String], rejected: [String]) {
        let parts = text.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var valid: [String] = []
        var rejected: [String] = []
        for part in parts {
            guard isPlausibleBundleID(part) else { rejected.append(part); continue }
            if seen.insert(part.lowercased()).inserted { valid.append(part) }
        }
        return (valid, rejected)
    }

    /// Appends `bundleID` unless already present (case-insensitive) or implausible.
    static func adding(_ bundleID: String, to list: [String]) -> [String] {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleBundleID(trimmed),
              !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return list }
        return list + [trimmed]
    }

    /// Removes `bundleID` (case-insensitive).
    static func removing(_ bundleID: String, from list: [String]) -> [String] {
        list.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
    }

    /// Bundle id of the `.app` at `url`, read from its Info.plist; nil when unreadable.
    static func bundleID(ofAppAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier.flatMap { isPlausibleBundleID($0) ? $0 : nil }
    }
}
