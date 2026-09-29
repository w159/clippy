import Foundation
import os

// SEC-01: managed-preference (MDM / configuration profile) support.
//
// A forced key already *reads* as the managed value through UserDefaults. What
// AppSettings adds is (a) setters that no-op for forced keys so the model never
// diverges from policy, and (b) `isForced` so Settings can show a lock badge.

extension AppSettings {
    /// Provider that reports which keys IT forced. Replace in tests; production
    /// uses UserDefaults' managed-preference state.
    nonisolated static var managed: ManagedPreferences {
        get { managedSlot.withLock { $0 } }
        set { managedSlot.withLock { $0 = newValue } }
    }
    private nonisolated static let managedSlot = OSAllocatedUnfairLock<ManagedPreferences>(initialState: .system())

    /// True when `key` is locked by a managed preference. Settings UI shows a lock
    /// badge and disables the control for these keys.
    nonisolated static func isForced(_ key: String) -> Bool {
        managed.isForced(key)
    }

    /// Instance convenience for views that hold the settings object.
    func isForced(_ key: String) -> Bool {
        Self.isForced(key)
    }

    /// The history cap as stored in UserDefaults, readable from any thread. The
    /// storage layer (database, archive import) runs off the main actor and must
    /// not touch the main-actor `AppSettings.shared`; `@AppDefault` reads the same
    /// key straight from `UserDefaults.standard`, so the value is identical.
    nonisolated static var storedMaxHistoryItems: Int {
        UserDefaults.standard.appDefaultRead(forKey: Keys.maxHistoryItems) ?? defaultMaxHistoryItems
    }

    /// Factory history cap; also the registered default.
    nonisolated static let defaultMaxHistoryItems = 500

    /// Every security-relevant key currently forced, for a policy summary.
    nonisolated static var forcedKeys: [String] {
        ManagedSettingKeys.all.filter { isForced($0) }
    }
}
