import Foundation

/// UserDefaults-backed switches for the automation surface (URL scheme, Spotlight,
/// CLI). Kept out of `AppSettings` on purpose; every key is prefixed `automation.`.
///
/// Keys:
/// - `automation.urlSchemeWrites` (Bool, default false): `clippy://add` and
///   `clippy://paste-latest` run without a prompt.
/// - `automation.spotlightIndexing` (Bool, default false): donate non-sensitive
///   clip titles/previews to Spotlight. Text leaves Clippy for the system index,
///   so this is explicit opt-in.
/// - `automation.cliInstallPath` (String): where the CLI symlink was last installed.
struct AutomationSettings {
    static let urlSchemeWritesKey = "automation.urlSchemeWrites"
    static let spotlightIndexingKey = "automation.spotlightIndexing"
    static let cliInstallPathKey = "automation.cliInstallPath"

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests never touch the real domain.
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Whether mutating URL actions skip the once-per-session prompt.
    var allowURLSchemeWrites: Bool {
        get { defaults.bool(forKey: Self.urlSchemeWritesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.urlSchemeWritesKey) }
    }

    /// Whether clips are donated to Spotlight (default off).
    var spotlightIndexingEnabled: Bool {
        get { defaults.bool(forKey: Self.spotlightIndexingKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.spotlightIndexingKey) }
    }

    /// Last CLI install location, if any.
    var cliInstallPath: String? {
        get { defaults.string(forKey: Self.cliInstallPathKey) }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Self.cliInstallPathKey) }
            else { defaults.removeObject(forKey: Self.cliInstallPathKey) }
        }
    }
}
