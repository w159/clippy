import Foundation

// SET-09: versioned export/import of preferences. Secrets never leave the Mac and
// import only ever writes keys from the known set.

/// A JSON-representable preference value.
enum PreferenceValue: Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case map([String: String])

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Int.self) { self = .int(value) }
        else if let value = try? box.decode(Double.self) { self = .double(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([String].self) { self = .strings(value) }
        else if let value = try? box.decode([String: String].self) { self = .map(value) }
        else { throw DecodingError.dataCorruptedError(in: box, debugDescription: "Unsupported preference value") }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try box.encode(value)
        case .int(let value): try box.encode(value)
        case .double(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .strings(let value): try box.encode(value)
        case .map(let value): try box.encode(value)
        }
    }

    /// Converts a UserDefaults property-list object; nil for unsupported types.
    init?(defaultsObject object: Any?) {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                self = .int(number.intValue)
            } else { self = .double(number.doubleValue) }
        case let text as String: self = .string(text)
        case let list as [String]: self = .strings(list)
        case let dict as [String: String]: self = .map(dict)
        default: return nil
        }
    }

    /// Property-list object to store in UserDefaults.
    var defaultsObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .strings(let value): return value
        case .map(let value): return value
        }
    }
}

/// Errors raised by import validation.
enum SettingsImportError: Error, Equatable, LocalizedError {
    case notPreferencesFile
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notPreferencesFile: return "This is not a Clippy preferences file."
        case .unsupportedVersion(let version): return "Preferences version \(version) is not supported by this Clippy."
        }
    }
}

/// What an import would do, computed before anything is written.
struct SettingsImportPlan: Equatable {
    struct Change: Equatable {
        let key: String
        let old: PreferenceValue?
        let new: PreferenceValue
    }

    /// Why a key in the file was refused.
    enum RejectionReason: String, Equatable {
        case unknown = "not a known setting"
        case secret = "secrets are never imported"
        case managed = "managed by your organization"
    }

    struct Rejection: Equatable {
        let key: String
        let reason: RejectionReason
    }

    /// Ordinary changes, applied on confirmation of the whole import.
    var changes: [Change] = []
    /// Security-relevant changes; each is applied only when its key is confirmed individually.
    var requiresConfirmation: [Change] = []
    var unchangedCount = 0
    /// Refused keys with reasons; never written.
    var rejected: [Rejection] = []

    var unknownKeys: [String] { keys(.unknown) }
    var secretKeys: [String] { keys(.secret) }
    var managedKeys: [String] { keys(.managed) }

    private func keys(_ reason: RejectionReason) -> [String] { rejected.filter { $0.reason == reason }.map(\.key) }

    /// Human summary shown before the user confirms.
    var summary: String {
        let total = changes.count + requiresConfirmation.count
        var parts = ["\(total) setting\(total == 1 ? "" : "s") will change"]
        if !requiresConfirmation.isEmpty { parts.append("\(requiresConfirmation.count) need individual confirmation") }
        if unchangedCount > 0 { parts.append("\(unchangedCount) already match") }
        if !rejected.isEmpty {
            parts.append("\(rejected.count) skipped (unknown \(unknownKeys.count), secret \(secretKeys.count), managed \(managedKeys.count))")
        }
        return parts.joined(separator: ", ") + "."
    }
}

/// Export/import engine over an injectable UserDefaults and key allowlist.
struct SettingsPreferencesPorter {
    /// File format version written and accepted.
    static let currentVersion = 1
    private static let secretMarkers = ["apikey", "token", "secret", "keychain", "credential"]

    private struct Document: Codable {
        var format = "clippy-preferences"
        var version: Int
        var exportedAt: String
        var values: [String: PreferenceValue]
    }

    /// Keys that may be exported/imported.
    let knownKeys: Set<String>

    init(knownKeys: Set<String>) { self.knownKeys = knownKeys }

    /// True when the key name looks like it holds a secret.
    static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return secretMarkers.contains { lowered.contains($0) }
    }

    /// JSON for every known, non-secret key that has a stored value.
    func export(from defaults: UserDefaults, now: Date = Date()) throws -> Data {
        var values: [String: PreferenceValue] = [:]
        for key in knownKeys where !Self.isSecretKey(key) {
            if let value = PreferenceValue(defaultsObject: defaults.object(forKey: key)) { values[key] = value }
        }
        let document = Document(version: Self.currentVersion, exportedAt: ISO8601DateFormatter().string(from: now), values: values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Validates `data` and describes the changes without writing.
    func plan(importing data: Data, against defaults: UserDefaults,
              isForced: (String) -> Bool = { AppSettings.isForced($0) }) throws -> SettingsImportPlan {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw SettingsImportError.notPreferencesFile }
        guard document.format == "clippy-preferences" else { throw SettingsImportError.notPreferencesFile }
        guard document.version == Self.currentVersion else { throw SettingsImportError.unsupportedVersion(document.version) }
        var plan = SettingsImportPlan()
        for key in document.values.keys.sorted() {
            guard let value = document.values[key] else { continue }
            if Self.isSecretKey(key) { plan.rejected.append(.init(key: key, reason: .secret)); continue }
            guard knownKeys.contains(key) else { plan.rejected.append(.init(key: key, reason: .unknown)); continue }
            if isForced(key) { plan.rejected.append(.init(key: key, reason: .managed)); continue }
            let old = PreferenceValue(defaultsObject: defaults.object(forKey: key))
            guard old != value else { plan.unchangedCount += 1; continue }
            let change = SettingsImportPlan.Change(key: key, old: old, new: value)
            if Self.isSecurityRelevant(key) { plan.requiresConfirmation.append(change) } else { plan.changes.append(change) }
        }
        return plan
    }

    /// Writes the validated changes, plus only those security-relevant changes whose key is in `confirmed`.
    func apply(_ plan: SettingsImportPlan, to defaults: UserDefaults, confirmed: Set<String> = []) {
        for change in plan.changes { defaults.set(change.new.defaultsObject, forKey: change.key) }
        for change in plan.requiresConfirmation where confirmed.contains(change.key) {
            defaults.set(change.new.defaultsObject, forKey: change.key)
        }
    }

    /// Keys whose change can widen what the app may do or weaken protection: managed-policy keys,
    /// code/script execution, MCP, app lock, retention and per-script sandbox flags.
    static func isSecurityRelevant(_ key: String) -> Bool {
        ManagedSettingKeys.all.contains(key) || key.hasPrefix("sandbox.script.")
            || key == AppSettings.Keys.aiAgentAllowCodeExecution || key == AppSettings.Keys.aiAgentAllowScripts
            || key == AppSettings.Keys.mcpEnabled
    }
}
