import Foundation

/// User/IT-defined retention policy (FEAT-10). Persisted as JSON in
/// UserDefaults under `RetentionPreferences.rulesKey`.
struct RetentionRules: Codable, Equatable {
    /// Master switch. Off by default: nothing is ever deleted unless enabled.
    var isEnabled = false
    /// "Forget after N days" for every clip. nil = no global limit.
    var forgetAfterDays: Int?
    /// Per-kind TTL in days, keyed by `ClipContentKind.rawValue`.
    var kindTTLDays: [String: Int] = [:]
    /// Per-app TTL in days, keyed by source app bundle ID.
    var appTTLDays: [String: Int] = [:]
    /// Auto-expire clips `SensitiveContent.isSensitive(clip:)` flags, after N hours.
    var sensitiveTTLHours: Int?
    /// When true the rules also apply to pinned (categorized) clips. Default
    /// false: pinned/categorized clips never expire unless this is set explicitly.
    var includeCategorized = false

    /// Shortest applicable TTL for a clip, in seconds; nil when no rule applies.
    func ttl(kind: ClipContentKind, bundleID: String?, isSensitive: Bool) -> (seconds: TimeInterval, reason: RetentionReason)? {
        var best: (TimeInterval, RetentionReason)?
        func consider(_ seconds: TimeInterval, _ reason: RetentionReason) {
            guard seconds >= 0 else { return }
            if best == nil || seconds < best!.0 { best = (seconds, reason) }
        }
        if let days = forgetAfterDays { consider(TimeInterval(days) * 86_400, .forgetAfter) }
        if let days = kindTTLDays[kind.rawValue] { consider(TimeInterval(days) * 86_400, .kind) }
        if let bundleID, let days = appTTLDays[bundleID] { consider(TimeInterval(days) * 86_400, .app) }
        if isSensitive, let hours = sensitiveTTLHours { consider(TimeInterval(hours) * 3_600, .sensitive) }
        return best
    }
}

/// Which rule expired a clip.
enum RetentionReason: String, Codable {
    case forgetAfter, kind, app, sensitive
}

/// Persistence for the rules, plus the SEC-01 forced check.
struct RetentionPreferences {
    static let rulesKey = "security.retention.rules"

    private let defaults: UserDefaults
    private let managed: ManagedPreferences

    init(defaults: UserDefaults = .standard, managed: ManagedPreferences = .system()) {
        self.defaults = defaults
        self.managed = managed
    }

    /// Current rules. A missing or undecodable value is "disabled, no rules".
    var rules: RetentionRules {
        get {
            guard let data = defaults.data(forKey: Self.rulesKey),
                  let decoded = try? JSONDecoder().decode(RetentionRules.self, from: data) else {
                return RetentionRules()
            }
            return decoded
        }
        nonmutating set {
            guard !managed.isForced(Self.rulesKey) else { return }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.rulesKey)
        }
    }
}
