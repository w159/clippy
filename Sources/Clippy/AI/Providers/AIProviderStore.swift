import Foundation
import Combine

/// Owns the user's configured providers, their credentials, and `resolve()`, the one
/// place that turns "what the user set up" into "what a request needs".
@MainActor
final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()

    enum Keys {
        static let instances = "aiProviderInstances"
        static let activeID = "aiActiveProviderID"
        static let migrated = "aiProviderMigratedV1"
        // Owned by AppSettings; read here for the master switch and legacy migration.
        static let enabled = "aiEnabled"
        static let legacyProvider = "aiProvider"
        static let legacyBaseURL = "aiBaseURL"
        static let legacyModel = "aiModel"
        static let legacyAPIVersion = "aiAzureAPIVersion"
    }

    @Published private(set) var instances: [ProviderInstance]
    @Published var activeID: UUID? {
        didSet { if activeID != oldValue { persistActive() } }
    }

    var active: ProviderInstance? {
        activeID.flatMap { id in instances.first { $0.id == id } }
    }

    private var migrationError: AIError?
    private let defaults: UserDefaults
    private let secrets: AISecretStore
    private let isForced: @Sendable (String) -> Bool

    init(defaults: UserDefaults = .standard,
         secrets: AISecretStore = .keychain(),
         isForced: @escaping @Sendable (String) -> Bool = { AppSettings.isForced($0) }) {
        self.defaults = defaults
        self.secrets = secrets
        self.isForced = isForced
        if let data = defaults.data(forKey: Keys.instances),
           let decoded = try? JSONDecoder().decode([ProviderInstance].self, from: data) {
            instances = decoded
        } else {
            instances = []
        }
        activeID = defaults.string(forKey: Keys.activeID).flatMap(UUID.init(uuidString:))
        migrateLegacyIfNeeded()
    }

    /// Re-reads the persisted instances and active selection after Reset / Import rewrote
    /// the defaults behind this store's back. Secrets are never touched. An empty result
    /// re-arms the one-time legacy migration so the default instance comes back.
    func reloadFromDefaults() {
        var loaded: [ProviderInstance] = []
        if let data = defaults.data(forKey: Keys.instances),
           let decoded = try? JSONDecoder().decode([ProviderInstance].self, from: data) {
            loaded = decoded
        }
        migrationError = nil
        instances = loaded
        let stored = defaults.string(forKey: Keys.activeID).flatMap(UUID.init(uuidString:))
        activeID = stored.flatMap { id in loaded.contains { $0.id == id } ? id : nil } ?? loaded.first?.id
        if loaded.isEmpty { defaults.removeObject(forKey: Keys.migrated) }
        migrateLegacyIfNeeded()
    }

    // MARK: - Instances

    @discardableResult
    func add(descriptorID: String) -> ProviderInstance {
        let descriptor = ProviderCatalog.descriptor(id: descriptorID)
        var instance = descriptor.map(Self.makeInstance)
            ?? ProviderInstance(descriptorID: descriptorID, name: descriptorID)
        instance.name = uniqueName(instance.name)
        instances.append(instance)
        if activeID == nil { activeID = instance.id }
        persistInstances()
        return instance
    }

    func update(_ instance: ProviderInstance) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        var stored = instance
        let oldSecrets = Set(instances[index].headers.filter(\.isSecret).map(\.id))
        for position in stored.headers.indices where stored.headers[position].isSecret {
            let header = stored.headers[position]
            let account = ProviderInstance.headerAccount(instance: instance.id, header: header.id)
            // Empty means "unchanged": the value already lives in the Keychain.
            if !header.value.isEmpty, !secrets.write(account, header.value) { return }
            stored.headers[position].value = ""
        }
        let newSecrets = Set(stored.headers.filter(\.isSecret).map(\.id))
        for gone in oldSecrets.subtracting(newSecrets) {
            secrets.delete(ProviderInstance.headerAccount(instance: instance.id, header: gone))
        }
        instances[index] = stored
        persistInstances()
    }

    func remove(id: UUID) {
        guard let instance = instances.first(where: { $0.id == id }) else { return }
        secrets.delete(ProviderInstance.keyAccount(id))
        for header in instance.headers where header.isSecret {
            secrets.delete(ProviderInstance.headerAccount(instance: id, header: header.id))
        }
        instances.removeAll { $0.id == id }
        if activeID == id { activeID = instances.first?.id }
        persistInstances()
    }

    func setActive(_ id: UUID) {
        guard instances.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    // MARK: - Credentials

    func apiKey(for id: UUID) -> KeychainReadResult {
        secrets.read(ProviderInstance.keyAccount(id))
    }

    func setAPIKey(_ key: String, for id: UUID) {
        let account = ProviderInstance.keyAccount(id)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { secrets.delete(account) } else { _ = secrets.write(account, trimmed) }
    }

    /// The stored value of a secret header (for editing UIs); nil when unset.
    func secretHeaderValue(instance: UUID, header: UUID) -> String? {
        if case .value(let value) = secrets.read(ProviderInstance.headerAccount(instance: instance, header: header)) {
            return value
        }
        return nil
    }

    // MARK: - Resolve

    /// Explains precisely why AI cannot run, or returns everything a transport needs.
    /// Managed (MDM) forced provider / endpoint / model settings win over stored ones.
    func resolve(_ id: UUID? = nil, ignoringEnabled: Bool = false) -> Result<ResolvedProvider, AIError> {
        resolveInternal(id, ignoringEnabled: ignoringEnabled, lenient: false)
    }

    /// For browsing public model catalogs during first setup: ignores the master switch and
    /// skips the missing model / deployment / API key checks. Managed overrides
    /// and endpoint validity still apply. A denied Keychain read yields an empty credential and
    /// `keychainDeniedStatus` instead of a failure.
    func resolveForModels(_ id: UUID?) -> Result<ResolvedProvider, AIError> {
        resolveInternal(id, ignoringEnabled: true, lenient: true)
    }

    private func resolveInternal(_ id: UUID?, ignoringEnabled: Bool, lenient: Bool) -> Result<ResolvedProvider, AIError> {
        guard ignoringEnabled || defaults.bool(forKey: Keys.enabled) else {
            return .failure(.notConfigured("AI features are turned off in Settings."))
        }
        var keyAccount: String?
        guard var instance = pickInstance(id, keyAccount: &keyAccount) else {
            return .failure(migrationError ?? .notConfigured("No AI provider is set up. Add one in Settings > AI."))
        }
        applyManagedOverrides(to: &instance)
        guard let descriptor = ProviderCatalog.descriptor(id: instance.descriptorID) else {
            return .failure(.notConfigured("Unknown provider \"\(instance.descriptorID)\". Pick another in Settings > AI."))
        }
        guard descriptor.isActive else {
            return .failure(.notConfigured("\(descriptor.displayName) is no longer available. Pick another provider in Settings > AI."))
        }
        if descriptor.family == .appleFoundation {
            if let reason = AppleIntelligence.availability.reason { return .failure(.notConfigured(reason)) }
            return .success(ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: "", secretHeaders: [:]))
        }
        let draft = ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: "", secretHeaders: [:])
        if let failure = validateEndpoint(draft, requireModelFields: !lenient) { return .failure(failure) }

        var apiKey = ""
        var deniedStatus: OSStatus?
        switch secrets.read(keyAccount ?? ProviderInstance.keyAccount(instance.id)) {
        case .value(let value): apiKey = value
        case .missing: break
        case .denied(let status):
            if !lenient {
                return .failure(.notConfigured(
                    "Clippy could not read the \(instance.name) API key from the Keychain (status \(status)). "
                        + "Unlock the keychain or re-enter the key in Settings."))
            }
            deniedStatus = status
        }
        if !lenient && descriptor.requiresAPIKey && apiKey.isEmpty {
            return .failure(.notConfigured("\(instance.name) needs an API key (set it in Settings)."))
        }

        var secretHeaders: [String: String] = [:]
        for header in instance.headers where header.isSecret && !header.name.isEmpty {
            switch secrets.read(ProviderInstance.headerAccount(instance: instance.id, header: header.id)) {
            case .value(let value):
                secretHeaders[header.name.trimmingCharacters(in: .whitespacesAndNewlines)] = value
            case .missing: break
            case .denied(let status):
                if !lenient {
                    return .failure(.notConfigured(
                        "Clippy could not read the secret header \"\(header.name)\" from the Keychain (status \(status))."))
                }
                deniedStatus = status
            }
        }
        return .success(ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: apiKey,
                                         secretHeaders: secretHeaders, keychainDeniedStatus: deniedStatus))
    }

    /// The instance a request would use (explicit id, else active) with managed (MDM)
    /// overrides applied, for showing forced values read-only in Settings. Performs no
    /// credential reads, so a locked Keychain cannot fail it. When IT forces a provider the
    /// user never added, the result is synthetic (not in `instances`): display it, never `update` it.
    func presentationInstance(_ id: UUID? = nil) -> ProviderInstance? {
        var unusedKeyAccount: String?
        guard var instance = pickInstance(id, keyAccount: &unusedKeyAccount) else { return nil }
        applyManagedOverrides(to: &instance)
        return instance
    }

    // MARK: - Resolve helpers

    private func pickInstance(_ id: UUID?, keyAccount: inout String?) -> ProviderInstance? {
        if isForced(Keys.legacyProvider),
           let kind = defaults.string(forKey: Keys.legacyProvider) {
            let forcedBase = isForced(Keys.legacyBaseURL) ? defaults.string(forKey: Keys.legacyBaseURL) ?? "" : ""
            let descriptorID = Self.legacyDescriptorID(kind: kind, baseURL: forcedBase)
            if let existing = instances.first(where: { $0.descriptorID == descriptorID }) { return existing }
            // IT forced a provider the user never set up: use it with the pre-migration key slot.
            keyAccount = "ai.\(kind).apiKey"
            return ProviderCatalog.descriptor(id: descriptorID).map(Self.makeInstance)
        }
        if let id { return instances.first { $0.id == id } }
        return active
    }

    private func applyManagedOverrides(to instance: inout ProviderInstance) {
        if isForced(Keys.legacyBaseURL), let base = defaults.string(forKey: Keys.legacyBaseURL) {
            instance.baseURL = base
        }
        if isForced(Keys.legacyModel), let model = defaults.string(forKey: Keys.legacyModel) {
            instance.model = model
            if instance.descriptorID.hasPrefix("azure") { instance.deployment = model }
        }
        if isForced(Keys.legacyAPIVersion), let version = defaults.string(forKey: Keys.legacyAPIVersion) {
            instance.apiVersion = version
        }
    }

    private func validateEndpoint(_ resolved: ResolvedProvider, requireModelFields: Bool) -> AIError? {
        let descriptor = resolved.descriptor
        let name = resolved.instance.name
        switch resolved.baseURLResult {
        case .success: break
        case .failure(.empty):
            return .notConfigured("\(name) needs an endpoint URL (set it in Settings).")
        case .failure(.placeholder):
            return .notConfigured("\(name) endpoint not configured. Set your resource endpoint in Settings "
                + "(e.g. https://my-resource.openai.azure.com).")
        case .failure:
            let raw = resolved.instance.baseURL.isEmpty ? descriptor.defaultBaseURL : resolved.instance.baseURL
            return .badURL(raw)
        }
        if requireModelFields, descriptor.fields.contains(.deployment), resolved.effectiveDeployment.isEmpty {
            return .notConfigured("\(name) needs an Azure deployment name (set it in Settings).")
        }
        if requireModelFields, descriptor.fields.contains(.model), resolved.effectiveModel.isEmpty {
            return .notConfigured("\(name) needs a model (set it in Settings).")
        }
        if descriptor.family == .azureDeployments {
            let version = resolved.instance.apiVersion.isEmpty
                ? (descriptor.queryParams["api-version"] ?? "") : resolved.instance.apiVersion
            if version.isEmpty { return .notConfigured("\(name) needs an api-version (set it in Settings).") }
        }
        return nil
    }

    // MARK: - Defaults

    private static func applyDefaults(_ descriptor: ProviderDescriptor, to instance: inout ProviderInstance) {
        instance.baseURL = descriptor.defaultBaseURL
        instance.model = descriptor.defaultModel ?? ""
        instance.apiVersion = descriptor.queryParams["api-version"] ?? ""
    }

    static func makeInstance(_ descriptor: ProviderDescriptor) -> ProviderInstance {
        var instance = ProviderInstance(descriptorID: descriptor.id, name: descriptor.displayName)
        applyDefaults(descriptor, to: &instance)
        instance.firstTokenTimeout = descriptor.family == .ollamaChat
            || HostLocality.isVerifiedLoopback(URL(string: instance.baseURL)) ? 300 : 60
        return instance
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(instances.map(\.name))
        if !taken.contains(base) { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Persistence

    private func persistInstances() {
        if let data = try? JSONEncoder().encode(instances) { defaults.set(data, forKey: Keys.instances) }
    }

    private func persistActive() {
        if let activeID { defaults.set(activeID.uuidString, forKey: Keys.activeID) }
        else { defaults.removeObject(forKey: Keys.activeID) }
    }

    // MARK: - Migration

    /// Which catalog entry the pre-instances provider setting maps to.
    static func legacyDescriptorID(kind: String, baseURL: String) -> String {
        switch kind {
        case "ollama":
            let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() ?? ""
            return host == "ollama.com" || host.hasSuffix(".ollama.com") ? "ollama-cloud" : "ollama-local"
        case "openai": return "openai"
        case "anthropic": return "anthropic"
        case "azureFoundry": return "azure-deployments"
        default: return "apple-intelligence"
        }
    }

    /// One-time import of the single-provider settings. The old keys and Keychain items
    /// are left in place (managed preferences still reference them).
    private func migrateLegacyIfNeeded() {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        guard instances.isEmpty else {
            defaults.set(true, forKey: Keys.migrated)
            return
        }
        let kind = defaults.string(forKey: Keys.legacyProvider) ?? "appleIntelligence"
        let base = defaults.string(forKey: Keys.legacyBaseURL) ?? ""
        guard let descriptor = ProviderCatalog.descriptor(id: Self.legacyDescriptorID(kind: kind, baseURL: base)) else { return }
        var instance = Self.makeInstance(descriptor)
        if !base.isEmpty, descriptor.family != .appleFoundation { instance.baseURL = base }
        if let model = defaults.string(forKey: Keys.legacyModel), !model.isEmpty { instance.model = model }
        if descriptor.family == .azureDeployments {
            instance.deployment = instance.model
            if let version = defaults.string(forKey: Keys.legacyAPIVersion), !version.isEmpty {
                instance.apiVersion = version
            }
        }
        if descriptor.family != .appleFoundation {
            switch secrets.read("ai.\(kind).apiKey") {
            case .value(let key) where !key.isEmpty:
                guard secrets.write(ProviderInstance.keyAccount(instance.id), key) else {
                    migrationError = .notConfigured("Could not copy the existing API key to the Keychain. Unlock the keychain and restart Clippy.")
                    return
                }
            case .denied(let status):
                migrationError = .notConfigured("Could not read the existing API key from the Keychain (status \(status)). Unlock the keychain and restart Clippy.")
                return  // retry next launch rather than losing the key
            default: break
            }
        }
        instances = [instance]
        activeID = instance.id
        persistInstances()
        defaults.set(true, forKey: Keys.migrated)
    }
}
