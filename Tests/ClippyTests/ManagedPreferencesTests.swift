import Combine
import XCTest
@testable import Clippy

@MainActor
final class ManagedPreferencesTests: XCTestCase {

    private var savedProvider: ManagedPreferences!

    override func setUp() {
        super.setUp()
        savedProvider = AppSettings.managed
    }

    override func tearDown() {
        AppSettings.managed = savedProvider
        super.tearDown()
    }

    private func makeSuite() -> UserDefaults {
        let name = "clippy-managed-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    func testForcedKeyMakesAISwitchSetterANoOp() {
        let settings = AppSettings.shared
        let original = settings.aiAgentAllowScripts
        defer { settings.aiAgentAllowScripts = original }

        AppSettings.managed = .none
        settings.aiAgentAllowScripts = false
        AppSettings.managed = .forcing([AppSettings.Keys.aiAgentAllowScripts])
        settings.aiAgentAllowScripts = true
        XCTAssertFalse(settings.aiAgentAllowScripts, "a forced switch must ignore writes")
        XCTAssertTrue(settings.isForced(AppSettings.Keys.aiAgentAllowScripts))
        XCTAssertFalse(settings.isForced(AppSettings.Keys.aiAgentAllowCodeExecution))

        AppSettings.managed = .none
        settings.aiAgentAllowScripts = true
        XCTAssertTrue(settings.aiAgentAllowScripts, "unforced writes apply again")
    }

    func testForcedKeysDoNotAffectOtherSettings() {
        let settings = AppSettings.shared
        let original = settings.aiAgentAllowCodeExecution
        defer { settings.aiAgentAllowCodeExecution = original }
        AppSettings.managed = .forcing([AppSettings.Keys.aiAgentAllowScripts])
        settings.aiAgentAllowCodeExecution = !original
        XCTAssertEqual(settings.aiAgentAllowCodeExecution, !original)
    }

    func testForcedMcpEnabledRejectsWriteWithoutEmittingIt() {
        let settings = AppSettings.shared
        let original = settings.mcpEnabled
        defer { AppSettings.managed = .none; settings.mcpEnabled = original }
        AppSettings.managed = .none
        settings.mcpEnabled = false

        var emitted: [Bool] = []
        let cancellable = settings.$mcpEnabled.dropFirst().sink { emitted.append($0) }
        defer { cancellable.cancel() }

        AppSettings.managed = .forcing([AppSettings.Keys.mcpEnabled])
        settings.mcpEnabled = true
        XCTAssertFalse(settings.mcpEnabled)
        XCTAssertEqual(emitted, [], "a rejected write must never reach subscribers (it would start the MCP server)")

        AppSettings.managed = .none
        settings.mcpEnabled = true
        XCTAssertTrue(settings.mcpEnabled)
        XCTAssertEqual(emitted, [true], "an accepted write emits exactly once")
    }

    func testForcedOnePasswordDelayIsReadOnlyAndUnforcedWritesClamp() {
        let settings = AppSettings.shared
        let original = settings.onePasswordAutoClearDelaySecs
        defer { AppSettings.managed = .none; settings.onePasswordAutoClearDelaySecs = original }
        AppSettings.managed = .none
        settings.onePasswordAutoClearDelaySecs = 45

        var emitted: [Int] = []
        let cancellable = settings.$onePasswordAutoClearDelaySecs.dropFirst().sink { emitted.append($0) }
        defer { cancellable.cancel() }

        AppSettings.managed = .forcing([AppSettings.Keys.onePasswordAutoClearDelaySecs])
        settings.onePasswordAutoClearDelaySecs = 600
        XCTAssertEqual(settings.onePasswordAutoClearDelaySecs, 45)
        XCTAssertTrue(emitted.isEmpty)

        AppSettings.managed = .none
        settings.onePasswordAutoClearDelaySecs = 99_999
        XCTAssertEqual(settings.onePasswordAutoClearDelaySecs, 600)
        settings.onePasswordAutoClearDelaySecs = 1
        XCTAssertEqual(settings.onePasswordAutoClearDelaySecs, 10)
        XCTAssertEqual(emitted, [600, 10])
    }

    func testForcedKeysListsOnlyForcedSecurityKeys() {
        AppSettings.managed = .forcing([AppSettings.Keys.aiEnabled, "notASecurityKey"])
        XCTAssertEqual(AppSettings.forcedKeys, [AppSettings.Keys.aiEnabled])
    }

    func testWebSearchDefaultsToOff() {
        let suite = makeSuite()
        AppSettings.registerDefaults(suite)
        XCTAssertEqual(suite.object(forKey: AppSettings.Keys.aiAgentAllowWebSearch) as? Bool, false)
        XCTAssertEqual(suite.object(forKey: AppSettings.Keys.aiAgentAllowScripts) as? Bool, false)
        XCTAssertEqual(suite.object(forKey: AppSettings.Keys.aiAgentAllowCodeExecution) as? Bool, false)
    }

    func testSystemProviderReportsUnforcedForOrdinarySuite() {
        let suite = makeSuite()
        suite.set(true, forKey: "aiEnabled")
        XCTAssertFalse(ManagedPreferences.system(suite).isForced("aiEnabled"),
                       "a value the user wrote is not a managed value")
    }

    func testAppLockPreferencesHonourForcedKeysAndClamp() {
        let suite = makeSuite()
        var prefs = AppLockPreferences(defaults: suite, managed: .none)
        XCTAssertFalse(prefs.isEnabled)
        XCTAssertEqual(prefs.idleMinutes, AppLockPreferences.defaultIdleMinutes)
        prefs.idleMinutes = 100_000
        XCTAssertEqual(prefs.idleMinutes, 240)
        prefs.idleMinutes = -3
        XCTAssertEqual(prefs.idleMinutes, 1)
        prefs.isEnabled = true

        prefs = AppLockPreferences(defaults: suite, managed: .forcing([AppLockPreferences.enabledKey]))
        prefs.isEnabled = false
        XCTAssertTrue(prefs.isEnabled, "forced key must keep its value")
    }

    func testRetentionPreferencesRoundTripAndForcedNoOp() {
        let suite = makeSuite()
        let prefs = RetentionPreferences(defaults: suite, managed: .none)
        XCTAssertEqual(prefs.rules, RetentionRules())
        var rules = RetentionRules()
        rules.isEnabled = true
        rules.forgetAfterDays = 30
        rules.kindTTLDays = ["image": 7]
        prefs.rules = rules
        XCTAssertEqual(prefs.rules, rules)

        let forced = RetentionPreferences(defaults: suite, managed: .forcing([RetentionPreferences.rulesKey]))
        forced.rules = RetentionRules()
        XCTAssertEqual(forced.rules, rules)

        suite.set(Data("garbage".utf8), forKey: RetentionPreferences.rulesKey)
        XCTAssertEqual(prefs.rules, RetentionRules(), "corrupt data means no rules, never a crash")
    }
}
