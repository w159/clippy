import Foundation

/// Draft of a smart collection being created or edited; produces a validated rule.
struct SmartCollectionDraft: Equatable {
    var name = ""
    var kinds: Set<ClipKindToken> = []
    var sourceApp = ""
    var textPattern = ""
    var olderThanDays = ""
    var newerThanDays = ""
    /// nil = either, true = only sensitive, false = only non-sensitive.
    var sensitive: Bool?

    /// Empty draft.
    init() {}

    /// Draft from an existing collection.
    init(collection: SmartCollection) {
        name = collection.name
        kinds = Set(collection.rule.kinds)
        sourceApp = collection.rule.sourceApp ?? ""
        textPattern = collection.rule.textPattern ?? ""
        olderThanDays = collection.rule.olderThanDays.map(String.init) ?? ""
        newerThanDays = collection.rule.newerThanDays.map(String.init) ?? ""
        sensitive = collection.rule.sensitive
    }

    /// Builds the rule, or throws the same errors the database would.
    func makeRule() throws -> SmartCollectionRule {
        var rule = SmartCollectionRule()
        rule.kinds = ClipKindToken.allCases.filter(kinds.contains)
        rule.sourceApp = Self.clean(sourceApp)
        rule.textPattern = Self.clean(textPattern)
        rule.olderThanDays = try Self.days(olderThanDays)
        rule.newerThanDays = try Self.days(newerThanDays)
        rule.sensitive = sensitive
        _ = try ClipDatabase.validate(name: name, rule: rule)
        return rule
    }

    /// User-facing text for a validation error.
    static func message(for error: Error) -> String {
        switch error as? SmartCollectionError {
        case .emptyName: return "Give the collection a name."
        case .emptyRule: return "Add at least one condition."
        case .invalidPattern: return "The text pattern is not a valid regular expression."
        case .invalidDays: return "Days must be a whole number of 1 or more."
        case .notFound: return "That collection no longer exists."
        case nil: return "Could not save the collection."
        }
    }

    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func days(_ text: String) throws -> Int? {
        guard let trimmed = clean(text) else { return nil }
        guard let value = Int(trimmed), value >= 1 else { throw SmartCollectionError.invalidDays }
        return value
    }

    /// One-line description of a rule for the list.
    static func summary(of rule: SmartCollectionRule) -> String {
        var parts: [String] = []
        if !rule.kinds.isEmpty { parts.append(rule.kinds.map(\.rawValue).joined(separator: "/")) }
        if let app = rule.sourceApp { parts.append("from \(app)") }
        if rule.textPattern != nil { parts.append("matches pattern") }
        if let days = rule.olderThanDays { parts.append("older than \(days)d") }
        if let days = rule.newerThanDays { parts.append("newer than \(days)d") }
        if let flag = rule.sensitive { parts.append(flag ? "sensitive" : "not sensitive") }
        return parts.isEmpty ? "No conditions" : parts.joined(separator: ", ")
    }
}
