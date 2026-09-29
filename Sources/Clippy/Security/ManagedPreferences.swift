import Foundation

/// Answers "did IT force this preference?" (SEC-01).
///
/// macOS delivers managed preferences (MDM configuration profiles, or
/// `defaults` written into /Library/Managed Preferences) through the same
/// UserDefaults API the app reads. A forced key always reads back as the
/// managed value, and `objectIsForced(forKey:)` reports whether that is the
/// case. `AppSettings` uses this to make forced settings read-only and to let
/// Settings show a lock badge.
///
/// The provider is injectable so tests can simulate forced keys without a
/// configuration profile.
struct ManagedPreferences: Sendable {
    /// Returns true when `key` is forced by a managed preference.
    let isForced: @Sendable (String) -> Bool

    /// Reads UserDefaults' own managed-preference state.
    static func system(_ defaults: UserDefaults = .standard) -> ManagedPreferences {
        ManagedPreferences { defaults.objectIsForced(forKey: $0) }
    }

    /// Nothing is forced. Useful as a test baseline.
    static let none = ManagedPreferences { _ in false }

    /// Treats exactly `keys` as forced. Test helper.
    static func forcing(_ keys: Set<String>) -> ManagedPreferences {
        ManagedPreferences { keys.contains($0) }
    }
}

/// Security-relevant settings IT may lock. The plist/mobileconfig sample in
/// docs/managed-preferences documents the same list.
enum ManagedSettingKeys {
    static let all: [String] = [
        AppSettings.Keys.aiEnabled,
        AppSettings.Keys.aiProvider,
        AppSettings.Keys.aiBaseURL,
        AppSettings.Keys.aiAutoSuggestTitles,
        AppSettings.Keys.aiAgentAllowScripts,
        AppSettings.Keys.aiAgentAllowCodeExecution,
        AppSettings.Keys.aiAgentAllowWebSearch,
        AppSettings.Keys.mcpEnabled,
        AppSettings.Keys.iCloudSyncEnabled,
        AppSettings.Keys.onePasswordAutoClearClipboard,
        AppSettings.Keys.onePasswordAutoClearDelaySecs,
        AppSettings.Keys.captureImages,
        AppSettings.Keys.captureFiles,
        AppSettings.Keys.suggestionsEnabled,
        AppSettings.Keys.suggestionsUseWindowText,
        AppLockPreferences.enabledKey,
        AppLockPreferences.idleMinutesKey,
        RetentionPreferences.rulesKey,
    ]
}
