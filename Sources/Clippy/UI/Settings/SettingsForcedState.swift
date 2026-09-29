import Foundation

// SEC-01 UI: what a control should look like when its key may be managed.

/// Presentation of a possibly managed setting.
struct SettingsForcedState: Equatable {
    /// Tooltip shown on the lock badge.
    static let lockHelp = "Managed by your organization"

    /// True when a managed preference locks the key.
    let isForced: Bool

    /// Resolves the state for `key` through an injectable provider (tests).
    init(key: String, isForced provider: (String) -> Bool = { AppSettings.isForced($0) }) {
        isForced = provider(key)
    }

    /// Controls are disabled while locked.
    var isDisabled: Bool { isForced }
    /// SF Symbol for the lock badge, nil when not locked.
    var lockSymbol: String? { isForced ? "lock.fill" : nil }
    /// Help text, nil when not locked.
    var help: String? { isForced ? Self.lockHelp : nil }
}
