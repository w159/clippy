import Foundation

/// Opt-in settings for link previews (FEAT-14). A preview fetch sends the address to the website,
/// so the feature is OFF by default.
/// UserDefaults keys: `preview.link.enabled` (Bool, default false), `preview.link.allowHosts` and
/// `preview.link.denyHosts` ([String], lowercase hosts; an empty allow list means any host not denied).
enum LinkPreviewPreferences {
    /// Honest disclosure shown next to the toggle.
    static let disclosure = "Fetches page title and icon from the website; the address is sent to that site."
    /// Defaults key: master switch.
    static let enabledKey = "preview.link.enabled"
    /// Defaults key: allow list.
    static let allowKey = "preview.link.allowHosts"
    /// Defaults key: deny list.
    static let denyKey = "preview.link.denyHosts"

    /// True only after the user turned link previews on.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hosts always previewed (when non-empty, only these are).
    static var allowHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: allowKey) ?? [] }
        set { UserDefaults.standard.set(normalize(newValue), forKey: allowKey) }
    }

    /// Hosts never previewed.
    static var denyHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: denyKey) ?? [] }
        set { UserDefaults.standard.set(normalize(newValue), forKey: denyKey) }
    }

    /// Lowercases, trims and de-duplicates host entries.
    static func normalize(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Deny wins; a non-empty allow list restricts; subdomains match their parent entry.
    static func isHostAllowed(_ host: String, allow: [String], deny: [String]) -> Bool {
        let lower = host.lowercased()
        func matches(_ entry: String) -> Bool { lower == entry || lower.hasSuffix("." + entry) }
        if deny.contains(where: matches) { return false }
        return allow.isEmpty || allow.contains(where: matches)
    }
}
