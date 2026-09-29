import Foundation

/// UserDefaults-backed snippet settings (keys prefixed `clippy.snippets.`):
/// - `clippy.snippets.expansionEnabled` (Bool, default false)
/// - `clippy.snippets.triggerMode` (String `immediate`/`onDelimiter`, default onDelimiter)
/// - `clippy.snippets.caseSensitive` (Bool, default true)
/// - `clippy.snippets.excludedBundleIDs` ([String], default `defaultExcludedBundleIDs`)
/// - `clippy.snippets.allowEnvPlaceholder` (Bool, default false)
enum SnippetSettings {
    /// Password managers and terminals, where expansion is off by default.
    static let defaultExcludedBundleIDs: [String] = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper"
    ]

    /// Defaults store; replaceable in tests.
    private static let seam = DefaultsSeam()
    static var defaults: UserDefaults {
        get { seam.value }
        set { seam.value = newValue }
    }

    private enum Key {
        static let enabled = "clippy.snippets.expansionEnabled"
        static let mode = "clippy.snippets.triggerMode"
        static let caseSensitive = "clippy.snippets.caseSensitive"
        static let excluded = "clippy.snippets.excludedBundleIDs"
        static let env = "clippy.snippets.allowEnvPlaceholder"
    }

    /// Global expansion toggle.
    static var isExpansionEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Commit rule for abbreviations.
    static var triggerMode: SnippetTriggerMode {
        get { defaults.string(forKey: Key.mode).flatMap(SnippetTriggerMode.init) ?? .onDelimiter }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// Case-sensitive matching.
    static var isCaseSensitive: Bool {
        get { defaults.object(forKey: Key.caseSensitive) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.caseSensitive) }
    }

    /// Bundle ids where expansion never runs.
    static var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.excluded) ?? defaultExcludedBundleIDs }
        set { defaults.set(newValue, forKey: Key.excluded) }
    }

    /// Whether `{env:NAME}` is expanded.
    static var allowEnvironmentPlaceholder: Bool {
        get { defaults.bool(forKey: Key.env) }
        set { defaults.set(newValue, forKey: Key.env) }
    }
}
