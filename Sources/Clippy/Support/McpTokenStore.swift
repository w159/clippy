import Foundation
import os
import Security

// MARK: - Secret storage abstraction

/// Minimal secret storage so token logic is testable without touching the real
/// Keychain. Production uses `KeychainSecretStore`; tests inject `InMemorySecretStore`.
protocol SecretStore: AnyObject, Sendable {
    /// The stored value for `account`, or nil when none exists.
    func read(account: String) throws -> String?
    /// Create or replace the value for `account`.
    func write(_ value: String, account: String) throws
    /// Remove the value for `account`. Removing a missing item is not an error.
    func delete(account: String) throws
}

enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(text)"
        }
    }
}

/// Generic-password items in the login Keychain, accessible only while the Mac is
/// unlocked and never synced to iCloud Keychain or migrated to another device.
final class KeychainSecretStore: SecretStore {
    /// Keychain `kSecAttrService` for every item Clippy's MCP integration stores.
    static let mcpService = "com.bytesavvy.clippy.mcp"

    private let service: String

    init(service: String = KeychainSecretStore.mcpService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }
}

/// Dictionary-backed store for tests.
final class InMemorySecretStore: SecretStore {
    private struct State {
        var values: [String: String] = [:]
        var failure: Error?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// When set, every operation throws it, to exercise failure paths.
    var failure: Error? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    func read(account: String) throws -> String? {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            return state.values[account]
        }
    }

    func write(_ value: String, account: String) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.values[account] = value
        }
    }

    func delete(account: String) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.values[account] = nil
        }
    }
}

// MARK: - Bearer token provider

/// The per-install bearer token that authenticates every request to Clippy's
/// loopback MCP endpoint (SEC-03). Generated on first use, kept in the Keychain,
/// passed to the node server through `CLIPPY_MCP_TOKEN` and written into installed
/// client configs. Never logged.
final class McpTokenProvider: Sendable {
    static let shared = McpTokenProvider(store: KeychainSecretStore())

    /// Keychain `kSecAttrAccount` of the token item (service `com.bytesavvy.clippy.mcp`).
    static let account = "bearer-token"
    /// Bytes of entropy per token (256 bits); encodes to 43 base64url characters.
    static let tokenByteCount = 32

    private let store: SecretStore
    private let lock = NSLock()

    init(store: SecretStore) {
        self.store = store
    }

    /// The current token, generating and persisting one on first use. A stored value
    /// too short to be one of ours (hand-edited, corrupt) is replaced.
    func token() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = try store.read(account: Self.account),
           existing.count >= Self.minimumLength {
            return existing
        }
        return try generateAndStore()
    }

    /// Replace the token. Callers must restart the server and re-sync installed
    /// client configs afterwards; the old token stops working immediately.
    @discardableResult
    func rotate() throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try generateAndStore()
    }

    /// Remove the stored token (uninstall / reset). The next `token()` makes a new one.
    func reset() throws {
        lock.lock(); defer { lock.unlock() }
        try store.delete(account: Self.account)
    }

    /// The node server refuses tokens shorter than this.
    static let minimumLength = 32

    private func generateAndStore() throws -> String {
        let fresh = try Self.generate()
        try store.write(fresh, account: Self.account)
        return fresh
    }

    /// 32 random bytes from the system CSPRNG as unpadded base64url.
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
