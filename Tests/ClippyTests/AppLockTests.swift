import XCTest
@testable import Clippy

@MainActor
final class AppLockTests: XCTestCase {

    /// Authenticator whose answer the test controls; can also hold the prompt open.
    @MainActor
    private final class FakeAuthenticator: AppLockAuthenticator {
        var succeeds = true
        var holdCompletion = false
        private(set) var promptCount = 0
        private var held: (@MainActor (Bool) -> Void)?
        func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
            promptCount += 1
            if holdCompletion { held = completion } else { completion(succeeds) }
        }
        func finishHeld(_ result: Bool) { held?(result); held = nil }
    }

    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeLock(enabled: Bool = true, idleMinutes: Int = 5, auth: FakeAuthenticator) -> AppLock {
        let suiteName = "clippy-applock-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let prefs = AppLockPreferences(defaults: suite, managed: .none)
        prefs.isEnabled = enabled
        prefs.idleMinutes = idleMinutes
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-applock-audit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AppLock(preferences: prefs, authenticator: auth, audit: AuditLog(directory: dir), now: { [unowned self] in clock })
    }

    func testStartsLockedWhenEnabledAndUnlockedWhenDisabled() {
        XCTAssertTrue(makeLock(auth: FakeAuthenticator()).isLocked)
        let off = makeLock(enabled: false, auth: FakeAuthenticator())
        XCTAssertFalse(off.isLocked)
        XCTAssertFalse(off.panelWillShow())
    }

    func testSuccessfulAuthenticationUnlocks() {
        let auth = FakeAuthenticator()
        let lock = makeLock(auth: auth)
        lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
        XCTAssertFalse(lock.lastAttemptFailed)
        XCTAssertFalse(lock.panelWillShow())
    }

    func testFailedAuthenticationStaysLockedAndFlagsFailure() {
        let auth = FakeAuthenticator()
        auth.succeeds = false
        let lock = makeLock(auth: auth)
        lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.lastAttemptFailed)
        XCTAssertTrue(lock.panelWillShow(), "panel keeps showing the lock view")
    }

    func testIdleTimeoutRelocksAndActivityResetsTheClock() {
        let lock = makeLock(idleMinutes: 5, auth: FakeAuthenticator())
        lock.unlock()
        clock.addTimeInterval(4 * 60)
        lock.lockIfIdle()
        XCTAssertFalse(lock.isLocked)
        lock.noteActivity()
        clock.addTimeInterval(4 * 60)
        lock.lockIfIdle()
        XCTAssertFalse(lock.isLocked, "activity restarted the countdown")
        clock.addTimeInterval(61)
        lock.lockIfIdle()
        XCTAssertTrue(lock.isLocked)
    }

    func testPanelOpenAfterIdleReportsLocked() {
        let lock = makeLock(idleMinutes: 1, auth: FakeAuthenticator())
        lock.unlock()
        clock.addTimeInterval(120)
        XCTAssertTrue(lock.panelWillShow())
    }

    func testReentrantUnlockWhilePromptIsUpIsIgnored() {
        let auth = FakeAuthenticator()
        auth.holdCompletion = true
        let lock = makeLock(auth: auth)
        lock.unlock()
        lock.unlock()
        XCTAssertEqual(auth.promptCount, 1)
        XCTAssertTrue(lock.isAuthenticating)
        auth.finishHeld(true)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isAuthenticating)
    }

    func testLockIsNoOpWhenFeatureDisabledAndUnlockNoOpWhenAlreadyOpen() {
        let auth = FakeAuthenticator()
        let off = makeLock(enabled: false, auth: auth)
        off.lock()
        XCTAssertFalse(off.isLocked)
        let on = makeLock(auth: auth)
        on.unlock()
        on.unlock()
        XCTAssertEqual(auth.promptCount, 1, "already unlocked: no second prompt")
    }
}
