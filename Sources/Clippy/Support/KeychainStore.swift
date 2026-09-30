import Foundation
import Security

/// Thin wrapper over the macOS keychain for storing secrets (AI API keys,
/// integration tokens) as generic-password items. Values never touch
/// UserDefaults. Keyed by a stable account string under one service.
struct KeychainStore {
    static let shared = KeychainStore(service: "com.bytesavvy.clippy.secrets")

    let service: String

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) a secret. Returns false if the keychain is unavailable
    /// (e.g. a headless CI run) so callers can degrade rather than crash.
    /// The label and description make the item human-readable in Keychain Access
    /// so a user auditing their keychain sees "Clippy - <account>" rather than a
    /// bare account string with no indication of which app wrote it.
    @discardableResult
    func write(_ value: String, account: String,
               label: String? = nil, description: String? = nil) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // Audit finding: Keychain items written without label/description.
        // Fall back to a readable label derived from the account so every item
        // shows up in Keychain Access with an obvious owner and purpose.
        query[kSecAttrLabel as String] = label ?? "Clippy - \(account)"
        query[kSecAttrDescription as String] = description ?? "Clippy secret for \(account)"
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Like `read`, but distinguishes "no item" from "the keychain refused" so callers
    /// can tell a missing key from a denied one.
    func readResult(account: String) -> KeychainReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .denied(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return .missing
        }
        return .value(value)
    }

    /// True when a non-empty secret exists for the account, without copying it.
    func has(account: String) -> Bool {
        guard let value = read(account: account) else { return false }
        return !value.isEmpty
    }

    @discardableResult
    func delete(account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary) == errSecSuccess
    }
}

/// Outcome of a keychain read that keeps the OSStatus on failure.
enum KeychainReadResult: Equatable, Sendable {
    case value(String)
    case missing
    case denied(OSStatus)
}
