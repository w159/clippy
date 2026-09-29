import Foundation

/// SEC-06 settings, UserDefaults-backed. Keys are prefixed `security.appLock.`.
/// Forced values (SEC-01) win: a forced key makes the setter a no-op.
struct AppLockPreferences {
    static let enabledKey = "security.appLock.enabled"
    static let idleMinutesKey = "security.appLock.idleMinutes"
    static let defaultIdleMinutes = 5
    static let idleRange = 1...240

    private let defaults: UserDefaults
    private let managed: ManagedPreferences

    init(defaults: UserDefaults = .standard, managed: ManagedPreferences = .system()) {
        self.defaults = defaults
        self.managed = managed
    }

    /// Whether the panel is protected by Touch ID / password. Off by default.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set {
            guard !managed.isForced(Self.enabledKey) else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    /// Minutes of inactivity after which the app re-locks. Clamped to 1...240.
    var idleMinutes: Int {
        get {
            let stored = defaults.integer(forKey: Self.idleMinutesKey)
            return stored == 0 ? Self.defaultIdleMinutes : min(Self.idleRange.upperBound, max(Self.idleRange.lowerBound, stored))
        }
        nonmutating set {
            guard !managed.isForced(Self.idleMinutesKey) else { return }
            defaults.set(min(Self.idleRange.upperBound, max(Self.idleRange.lowerBound, newValue)), forKey: Self.idleMinutesKey)
        }
    }
}
