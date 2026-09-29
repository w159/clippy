import Combine
import Foundation
import LocalAuthentication

/// Verifies the user's identity. The production implementation uses LAContext
/// (Touch ID with password fallback); tests inject a fake.
protocol AppLockAuthenticator {
    /// Calls `completion(true)` when the user authenticated. Never called with
    /// content; `reason` is the prompt shown by the system.
    @MainActor
    func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void)
}

/// LocalAuthentication-backed authenticator: biometrics, falling back to the
/// account password.
struct LocalAuthenticator: AppLockAuthenticator {
    @MainActor
    func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set means there is nothing to authenticate against;
            // stay locked rather than failing open.
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(success) } }
        }
    }
}

/// Optional app lock (SEC-06): the panel shows a lock view instead of history
/// while locked. Locks after `idleMinutes` without activity and whenever the
/// panel is opened while already locked. Main-thread only (UI state), like
/// the other observable settings objects.
@MainActor
final class AppLock: ObservableObject {

    static let shared = AppLock()

    /// True while history must not be shown. Starts locked when the feature is on.
    @Published private(set) var isLocked: Bool
    /// True while a system authentication prompt is up.
    @Published private(set) var isAuthenticating = false
    /// Set when the last attempt failed or was cancelled.
    @Published private(set) var lastAttemptFailed = false

    private let preferences: AppLockPreferences
    private let authenticator: AppLockAuthenticator
    private let audit: AuditLog
    private let now: () -> Date
    private var lastActivity: Date
    private var timer: Timer?

    init(preferences: AppLockPreferences = AppLockPreferences(),
         authenticator: AppLockAuthenticator = LocalAuthenticator(),
         audit: AuditLog = .shared,
         now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.audit = audit
        self.authenticator = authenticator
        self.now = now
        self.lastActivity = now()
        self.isLocked = preferences.isEnabled
    }

    /// Whether the feature is turned on.
    var isEnabled: Bool { preferences.isEnabled }

    /// Call whenever the panel opens. Applies the idle rule, then reports whether
    /// the panel content must be replaced by the lock view.
    @discardableResult
    func panelWillShow() -> Bool {
        guard preferences.isEnabled else { isLocked = false; return false }
        lockIfIdle()
        return isLocked
    }

    /// Record user activity (resets the idle countdown).
    func noteActivity() { lastActivity = now() }

    /// Locks when the idle limit has elapsed since the last activity.
    func lockIfIdle() {
        guard preferences.isEnabled, !isLocked else { return }
        if now().timeIntervalSince(lastActivity) >= TimeInterval(preferences.idleMinutes * 60) {
            lock()
        }
    }

    /// Locks immediately (also used when the feature is enabled).
    func lock() {
        guard preferences.isEnabled else { return }
        isLocked = true
        lastAttemptFailed = false
    }

    /// Prompts for authentication; unlocks on success. Re-entrant calls while a
    /// prompt is up are ignored.
    func unlock(reason: String = "Unlock Clippy to view your clipboard history") {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        authenticator.authenticate(reason: reason) { [weak self] success in
            guard let self else { return }
            self.isAuthenticating = false
            if success {
                self.isLocked = false
                self.lastAttemptFailed = false
                self.lastActivity = self.now()
                self.audit.record(actor: "user", action: "app_lock.unlock", detail: "", clipIDs: [])
            } else {
                self.lastAttemptFailed = true
            }
        }
    }

    /// Re-reads the preference (call after Settings toggles it).
    func preferencesChanged() {
        if preferences.isEnabled {
            if timer == nil { startTimer() }
        } else {
            isLocked = false
            timer?.invalidate(); timer = nil
        }
    }

    /// Starts the once-a-minute idle check. Safe to call more than once.
    func start() {
        preferencesChanged()
        if preferences.isEnabled && timer == nil { startTimer() }
    }

    /// Stops the idle timer (app shutdown). Does not change the locked state.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.lockIfIdle()
        }
    }
}
