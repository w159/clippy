import Foundation
import Combine

/// Editing operations and per-session state for the AI provider manager. All persistence
/// goes through `AIProviderStore`; this type only adds selection, test results and the
/// rules the store does not have (duplicate, secret-header blanking after save).
@MainActor
final class AIProviderManagerModel: ObservableObject {
    enum KeyStatus: Equatable {
        case stored, missing, denied(Int32)
    }

    let store: AIProviderStore
    @Published var selectedID: UUID?
    @Published var keyDrafts: [UUID: String] = [:]
    @Published private(set) var results: [UUID: AIConnectionOutcome] = [:]
    @Published private(set) var testing: Set<UUID> = []

    init(store: AIProviderStore = .shared) {
        self.store = store
        selectedID = store.activeID ?? store.instances.first?.id
    }

    // MARK: - List operations

    @discardableResult
    func add(descriptorID: String) -> ProviderInstance {
        let instance = store.add(descriptorID: descriptorID)
        selectedID = instance.id
        return instance
    }

    /// Copies every setting (and the credentials) into a new instance named "<name> copy".
    /// The copy is never made active.
    @discardableResult
    func duplicate(_ id: UUID) -> ProviderInstance? {
        guard let source = store.instances.first(where: { $0.id == id }) else { return nil }
        var copy = store.add(descriptorID: source.descriptorID)
        let taken = Set(store.instances.map(\.name))
        var name = "\(source.name) copy"
        var suffix = 2
        while taken.contains(name) { name = "\(source.name) copy \(suffix)"; suffix += 1 }
        copy.name = name
        copy.baseURL = source.baseURL
        copy.model = source.model
        copy.apiVersion = source.apiVersion
        copy.organization = source.organization
        copy.project = source.project
        copy.deployment = source.deployment
        copy.region = source.region
        copy.extraBodyJSON = source.extraBodyJSON
        copy.params = source.params
        copy.firstTokenTimeout = source.firstTokenTimeout
        copy.idleTimeout = source.idleTimeout
        copy.requestTimeout = source.requestTimeout
        copy.headers = source.headers.map { header in
            var new = HeaderEntry(name: header.name, value: header.value, isSecret: header.isSecret)
            if header.isSecret {
                new.value = store.secretHeaderValue(instance: source.id, header: header.id) ?? ""
            }
            return new
        }
        store.update(copy)
        if case .value(let key) = store.apiKey(for: source.id) { store.setAPIKey(key, for: copy.id) }
        selectedID = copy.id
        return store.instances.first { $0.id == copy.id }
    }

    /// Removes an instance. The store re-targets the active id; selection follows.
    func remove(_ id: UUID) {
        store.remove(id: id)
        results[id] = nil
        if selectedID == id { selectedID = store.activeID ?? store.instances.first?.id }
    }

    func setActive(_ id: UUID) {
        store.setActive(id)
    }

    // MARK: - Editing

    /// Persists `draft` when it differs from the stored instance, then blanks secret
    /// header values in `draft` (the store keeps them in the Keychain and treats an empty
    /// value as "unchanged").
    func commit(_ draft: inout ProviderInstance) {
        guard let stored = store.instances.first(where: { $0.id == draft.id }) else { return }
        guard stored != draft else { return }
        store.update(draft)
        for index in draft.headers.indices where draft.headers[index].isSecret {
            draft.headers[index].value = ""
        }
    }

    func keyStatus(for id: UUID) -> KeyStatus {
        switch store.apiKey(for: id) {
        case .value(let key): return key.isEmpty ? .missing : .stored
        case .missing: return .missing
        case .denied(let status): return .denied(status)
        }
    }

    /// Saves (or, when blank, clears) the key. Returns whether the Keychain now reflects it.
    @discardableResult
    func saveKey(_ key: String, for id: UUID) -> Bool {
        store.setAPIKey(key, for: id)
        let expectStored = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch keyStatus(for: id) {
        case .stored: return expectStored
        case .missing: return !expectStored
        case .denied: return false
        }
    }

    struct TestFailure: Error, ExpressibleByStringLiteral {
        let message: String
        init(stringLiteral value: String) { message = value }
        init(_ message: String) { self.message = message }
    }

    // MARK: - Test connection

    /// Builds what a request needs without the master-switch gate, so testing works while AI
    /// is off. Returns a user-facing reason when the instance is not testable yet.
    func resolveForTest(_ instance: ProviderInstance) -> Result<ResolvedProvider, TestFailure> {
        store.resolve(instance.id, ignoringEnabled: true).mapError { TestFailure($0.localizedDescription) }
    }

    func test(_ id: UUID) async {
        guard let instance = store.instances.first(where: { $0.id == id }), !testing.contains(id) else { return }
        testing.insert(id)
        defer { testing.remove(id) }
        switch resolveForTest(instance) {
        case .failure(let reason):
            results[id] = AIConnectionOutcome(ok: false, summary: reason.message, detail: nil, latency: nil,
                                              requestURLDisplay: "\u{2014}")
        case .success(let resolved):
            results[id] = await AIConnectionRunner.run(resolved)
        }
    }

    /// Presentation state of the status dot in the provider list.
    enum Status: Equatable { case untested, testing, ok, failed }

    func status(for id: UUID) -> Status {
        if testing.contains(id) { return .testing }
        guard let result = results[id] else { return .untested }
        return result.ok ? .ok : .failed
    }
}
