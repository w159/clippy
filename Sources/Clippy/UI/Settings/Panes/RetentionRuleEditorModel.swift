import Foundation

/// Validation and edit operations over `RetentionRules`, kept pure so the editor view stays thin.
struct RetentionRuleEditorModel: Equatable {
    /// Why an edit was refused.
    enum EditError: Error, Equatable {
        case daysOutOfRange
        case emptyAppID
        case duplicate
    }

    /// Allowed TTL range in days.
    static let dayRange = 1...3650
    /// Allowed sensitive TTL range in hours.
    static let hourRange = 1...(24 * 365)

    /// The rules being edited.
    private(set) var rules: RetentionRules

    /// Creates a model over existing rules.
    init(rules: RetentionRules) { self.rules = rules }

    /// Enables or disables the whole rule set.
    mutating func setEnabled(_ enabled: Bool) { rules.isEnabled = enabled }

    /// Toggles whether categorized clips are also eligible.
    mutating func setIncludeCategorized(_ include: Bool) { rules.includeCategorized = include }

    /// Sets or clears the global "forget after N days" rule.
    mutating func setForgetAfter(days: Int?) throws {
        if let days { try Self.check(days) }
        rules.forgetAfterDays = days
    }

    /// Sets or clears the auto-expire-sensitive rule (hours).
    mutating func setSensitiveTTL(hours: Int?) throws {
        if let hours, !Self.hourRange.contains(hours) { throw EditError.daysOutOfRange }
        rules.sensitiveTTLHours = hours
    }

    /// Adds a per-kind TTL. A kind may only have one rule.
    mutating func addKindRule(kind: ClipContentKind, days: Int) throws {
        try Self.check(days)
        guard rules.kindTTLDays[kind.rawValue] == nil else { throw EditError.duplicate }
        rules.kindTTLDays[kind.rawValue] = days
    }

    /// Adds a per-app TTL keyed by bundle identifier. An app may only have one rule.
    mutating func addAppRule(bundleID: String, days: Int) throws {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(where: \.isWhitespace) else { throw EditError.emptyAppID }
        try Self.check(days)
        guard rules.appTTLDays[clean] == nil else { throw EditError.duplicate }
        rules.appTTLDays[clean] = days
    }

    /// Removes a per-kind rule.
    mutating func removeKindRule(_ kindKey: String) { rules.kindTTLDays[kindKey] = nil }

    /// Removes a per-app rule.
    mutating func removeAppRule(_ bundleID: String) { rules.appTTLDays[bundleID] = nil }

    /// Kind rules sorted by key for stable display.
    var kindRows: [(key: String, days: Int)] {
        rules.kindTTLDays.sorted { $0.key < $1.key }.map { (key: $0.key, days: $0.value) }
    }

    /// App rules sorted by bundle id for stable display.
    var appRows: [(key: String, days: Int)] {
        rules.appTTLDays.sorted { $0.key < $1.key }.map { (key: $0.key, days: $0.value) }
    }

    /// True when at least one rule is configured.
    var hasAnyRule: Bool {
        rules.forgetAfterDays != nil || rules.sensitiveTTLHours != nil || !rules.kindTTLDays.isEmpty || !rules.appTTLDays.isEmpty
    }

    /// User-facing text for an error.
    static func message(for error: EditError) -> String {
        switch error {
        case .daysOutOfRange: return "Enter a value between 1 and \(dayRange.upperBound) days."
        case .emptyAppID: return "Enter an app bundle identifier such as com.apple.Terminal."
        case .duplicate: return "A rule for that item already exists. Remove it first."
        }
    }

    private static func check(_ days: Int) throws {
        guard dayRange.contains(days) else { throw EditError.daysOutOfRange }
    }
}

/// Counts-only summary of a retention preview; never carries clip content.
struct RetentionPreviewSummary: Equatable {
    var total = 0
    var byReason: [RetentionReason: Int] = [:]

    /// Summarizes candidates by reason.
    init(candidates: [RetentionService.Candidate]) {
        total = candidates.count
        for candidate in candidates { byReason[candidate.reason, default: 0] += 1 }
    }

    /// One-line description for the preview result.
    var description: String {
        guard total > 0 else { return "Nothing would be deleted right now." }
        let parts = byReason.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) by \(Self.label($0.key))" }
        return "\(total) clip\(total == 1 ? "" : "s") would be deleted (\(parts.joined(separator: ", ")))."
    }

    private static func label(_ reason: RetentionReason) -> String {
        switch reason {
        case .forgetAfter: return "age rule"
        case .kind: return "type rule"
        case .app: return "app rule"
        case .sensitive: return "sensitive rule"
        }
    }
}
