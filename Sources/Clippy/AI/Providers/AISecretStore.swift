import Foundation
import Security

/// Where AI credentials live. Production uses the Keychain; tests use `inMemory()` so
/// they never touch the user's keychain.
struct AISecretStore: Sendable {
    var read: @Sendable (String) -> KeychainReadResult
    var write: @Sendable (String, String) -> Bool
    var delete: @Sendable (String) -> Void

    static func keychain(_ store: KeychainStore = .shared) -> AISecretStore {
        AISecretStore(
            read: { store.readResult(account: $0) },
            write: { store.write($1, account: $0) },
            delete: { store.delete(account: $0) })
    }

    /// Process-local store. `denying` makes every read report `errSecInteractionNotAllowed`.
    static func inMemory(denying: Bool = false) -> AISecretStore {
        let box = SecretBox()
        return AISecretStore(
            read: { denying ? .denied(errSecInteractionNotAllowed) : box.get($0) },
            write: { box.set($1, for: $0); return true },
            delete: { box.remove($0) })
    }
}

/// Lock-protected dictionary behind `AISecretStore.inMemory`.
/// `@unchecked Sendable`: every access to `values` happens under `lock`.
private final class SecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        return values[key].map { .value($0) } ?? .missing
    }

    func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}
