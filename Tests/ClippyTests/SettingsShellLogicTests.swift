import XCTest
@testable import Clippy

final class SettingsShellLogicTests: XCTestCase {
    private func entries() -> [SettingsSearchEntry] {
        [
            SettingsSearchEntry(id: "a", pane: "general", title: "Log level", keywords: ["logging"]),
            SettingsSearchEntry(id: "b", pane: "general", title: "Logging destination"),
            SettingsSearchEntry(id: "c", pane: "capture", title: "Ignored apps", keywords: ["blocklist"]),
            SettingsSearchEntry(id: "d", pane: "integrations", title: "MCP port"),
        ]
    }

    // MARK: Search

    func testExactTitleOutranksPrefixAndKeyword() {
        let hits = SettingsSearchIndex.search("log level", in: entries())
        XCTAssertEqual(hits.first?.id, "a")
    }

    func testPrefixOutranksKeyword() {
        let hits = SettingsSearchIndex.search("logging", in: entries())
        XCTAssertEqual(hits.map(\.id), ["b", "a"])
    }

    func testKeywordFindsRowAndBlankQueryReturnsNothing() {
        XCTAssertEqual(SettingsSearchIndex.search("blocklist", in: entries()).map(\.id), ["c"])
        XCTAssertTrue(SettingsSearchIndex.search("   ", in: entries()).isEmpty)
    }

    func testDiacriticsAndCaseFolded() {
        let list = [SettingsSearchEntry(id: "x", pane: "general", title: "Café mode")]
        XCTAssertEqual(SettingsSearchIndex.search("CAFE", in: list).count, 1)
    }

    func testAllTokensMustMatch() {
        XCTAssertTrue(SettingsSearchIndex.search("mcp banana", in: entries()).isEmpty)
    }

    func testCatalogPanesAreRegistered() {
        let panes = Set(SettingsPaneID.allCases.map(\.rawValue))
        for entry in SettingsSearchCatalog.entries { XCTAssertTrue(panes.contains(entry.pane), entry.id) }
    }

    // MARK: Forced state

    func testForcedStateDisablesAndLocks() {
        let locked = SettingsForcedState(key: "k", isForced: { $0 == "k" })
        XCTAssertTrue(locked.isDisabled)
        XCTAssertEqual(locked.help, "Managed by your organization")
        XCTAssertNotNil(locked.lockSymbol)
        let free = SettingsForcedState(key: "other", isForced: { _ in false })
        XCTAssertFalse(free.isDisabled)
        XCTAssertNil(free.help)
    }

    // MARK: File size presets

    func testNearestPreset() {
        XCTAssertEqual(FileSizePresets.nearest(toMB: 50), 25)
        XCTAssertEqual(FileSizePresets.nearest(toMB: 20), 25)
        XCTAssertEqual(FileSizePresets.nearest(toMB: 400), 500)
        XCTAssertEqual(FileSizePresets.nearest(toMB: 0), 1)
        XCTAssertEqual(FileSizePresets.nearest(toMB: 1000), 500)
    }

    func testOptionsKeepStoredNonPresetValue() {
        XCTAssertEqual(FileSizePresets.options(including: 50), [1, 5, 25, 50, 100, 250, 500])
        XCTAssertEqual(FileSizePresets.options(including: 25), FileSizePresets.stepsMB)
    }

    // MARK: Ignored apps

    func testBundleIDParsing() {
        let parsed = IgnoredAppsParser.parse("com.apple.finder\nbad id, com.Apple.Finder,single\n.leading.dot")
        XCTAssertEqual(parsed.valid, ["com.apple.finder"])
        XCTAssertEqual(parsed.rejected, ["bad id", "single", ".leading.dot"])
    }

    func testAddRemoveCaseInsensitive() {
        var list = IgnoredAppsParser.adding("com.a.b", to: [])
        list = IgnoredAppsParser.adding("COM.A.B", to: list)
        XCTAssertEqual(list, ["com.a.b"])
        XCTAssertEqual(IgnoredAppsParser.adding("nope", to: list), list)
        XCTAssertTrue(IgnoredAppsParser.removing("Com.A.B", from: list).isEmpty)
    }

    // MARK: Export / import

    private func scratch() -> UserDefaults {
        let name = "SettingsShellLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        suiteNames[ObjectIdentifier(defaults)] = name
        return defaults
    }

    private var suiteNames: [ObjectIdentifier: String] = [:]

    private func suiteName(of defaults: UserDefaults) -> String { suiteNames[ObjectIdentifier(defaults)] ?? "" }

    func testExportExcludesSecretsAndUnknownKeys() throws {
        let defaults = scratch()
        defaults.set(true, forKey: "aiEnabled")
        defaults.set("sk-secret", forKey: "aiApiKey")
        defaults.set("x", forKey: "unrelated")
        let porter = SettingsPreferencesPorter(knownKeys: ["aiEnabled", "aiApiKey"])
        let text = String(decoding: try porter.export(from: defaults), as: UTF8.self)
        XCTAssertTrue(text.contains("aiEnabled"))
        XCTAssertFalse(text.contains("aiApiKey"))
        XCTAssertFalse(text.contains("sk-secret"))
        XCTAssertFalse(text.contains("unrelated"))
    }

    func testImportRejectsUnknownSecretAndManagedKeys() throws {
        let source = scratch()
        source.set(7, forKey: "maxHistoryItems")
        let porter = SettingsPreferencesPorter(knownKeys: ["maxHistoryItems", "hideOnEscape"])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: porter.export(from: source)) as? [String: Any])
        var values = try XCTUnwrap(json["values"] as? [String: Any])
        values["evil"] = "1"
        values["mcpToken"] = "abc"
        values["hideOnEscape"] = false
        json["values"] = values
        let data = try JSONSerialization.data(withJSONObject: json)
        let target = scratch()
        let plan = try porter.plan(importing: data, against: target, isForced: { $0 == "hideOnEscape" })
        XCTAssertEqual(plan.changes.map(\.key), ["maxHistoryItems"])
        XCTAssertEqual(plan.unknownKeys, ["evil"])
        XCTAssertEqual(plan.secretKeys, ["mcpToken"])
        XCTAssertEqual(plan.managedKeys, ["hideOnEscape"])
        // Persisted data only: registered defaults are process-wide and visible through any suite.
        XCTAssertNil(target.persistentDomain(forName: suiteName(of: target))?["maxHistoryItems"], "plan must not write")
        porter.apply(plan, to: target)
        XCTAssertEqual(target.integer(forKey: "maxHistoryItems"), 7)
        XCTAssertNil(target.object(forKey: "evil"))
    }

    func testImportVersionAndFormatChecks() throws {
        let porter = SettingsPreferencesPorter(knownKeys: ["a"])
        let future = #"{"format":"clippy-preferences","version":99,"exportedAt":"x","values":{}}"#
        XCTAssertThrowsError(try porter.plan(importing: Data(future.utf8), against: scratch())) {
            XCTAssertEqual($0 as? SettingsImportError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try porter.plan(importing: Data("[1]".utf8), against: scratch())) {
            XCTAssertEqual($0 as? SettingsImportError, .notPreferencesFile)
        }
    }

    func testRoundTripPreservesTypes() throws {
        let defaults = scratch()
        defaults.set(true, forKey: "flag")
        defaults.set(3, forKey: "count")
        defaults.set(0.5, forKey: "ratio")
        defaults.set(["a", "b"], forKey: "list")
        defaults.set(["x": "plain"], forKey: "map")
        let porter = SettingsPreferencesPorter(knownKeys: ["flag", "count", "ratio", "list", "map"])
        let data = try porter.export(from: defaults)
        let target = scratch()
        porter.apply(try porter.plan(importing: data, against: target, isForced: { _ in false }), to: target)
        XCTAssertEqual(target.bool(forKey: "flag"), true)
        XCTAssertEqual(target.integer(forKey: "count"), 3)
        XCTAssertEqual(target.double(forKey: "ratio"), 0.5)
        XCTAssertEqual(target.stringArray(forKey: "list"), ["a", "b"])
        XCTAssertEqual(target.dictionary(forKey: "map") as? [String: String], ["x": "plain"])
        let again = try porter.plan(importing: data, against: target, isForced: { _ in false })
        XCTAssertTrue(again.changes.isEmpty)
        XCTAssertEqual(again.unchangedCount, 5)
    }

    func testExportableKeysExcludeSecretsAndLegacyGridColumnKey() {
        for key in SettingsPaneID.allExportableKeys { XCTAssertFalse(SettingsPreferencesPorter.isSecretKey(key), key) }
        XCTAssertFalse(SettingsPaneID.allExportableKeys.contains(AppSettings.Keys.clipColumns))
        XCTAssertTrue(SettingsPaneID.appearance.resetKeys.contains(AppSettings.Keys.clipColumns))
    }

    func testRejectionsCarryReasons() throws {
        let porter = SettingsPreferencesPorter(knownKeys: ["ok", "forcedKey"])
        let json = #"{"format":"clippy-preferences","version":1,"exportedAt":"x","values":{"ok":1,"zzz":1,"apiKeyX":"s","forcedKey":true}}"#
        let plan = try porter.plan(importing: Data(json.utf8), against: scratch(), isForced: { $0 == "forcedKey" })
        let reasons = Dictionary(uniqueKeysWithValues: plan.rejected.map { ($0.key, $0.reason) })
        XCTAssertEqual(reasons["zzz"], .unknown)
        XCTAssertEqual(reasons["apiKeyX"], .secret)
        XCTAssertEqual(reasons["forcedKey"], .managed)
        XCTAssertEqual(plan.changes.map(\.key), ["ok"])
    }

    /// Value persisted in the scratch suite itself, ignoring process-wide registered defaults.
    private func persisted(_ defaults: UserDefaults, _ key: String) -> Any? {
        defaults.persistentDomain(forName: suiteName(of: defaults))?[key]
    }

    func testSecurityRelevantKeysNeedPerKeyConfirmation() throws {
        let risky = [AppSettings.Keys.aiAgentAllowCodeExecution, AppSettings.Keys.mcpEnabled, "sandbox.script.1234"]
        let plain = "settingsShellTest.plainKey"
        let porter = SettingsPreferencesPorter(knownKeys: Set(risky + [plain]))
        let values = risky.map { "\"\($0)\":true" } + ["\"\(plain)\":true"]
        let json = "{\"format\":\"clippy-preferences\",\"version\":1,\"exportedAt\":\"x\",\"values\":{\(values.joined(separator: ","))}}"
        let target = scratch()
        // Registered defaults are process-wide; pin the risky keys to false in this suite so "true" is always a change.
        for key in risky { target.set(false, forKey: key) }
        let plan = try porter.plan(importing: Data(json.utf8), against: target, isForced: { _ in false })
        XCTAssertEqual(Set(plan.requiresConfirmation.map(\.key)), Set(risky))
        XCTAssertEqual(plan.changes.map(\.key), [plain])
        porter.apply(plan, to: target)
        for key in risky { XCTAssertEqual(persisted(target, key) as? Bool, false, key) }
        XCTAssertEqual(persisted(target, plain) as? Bool, true)
        porter.apply(plan, to: target, confirmed: [AppSettings.Keys.mcpEnabled])
        XCTAssertEqual(persisted(target, AppSettings.Keys.mcpEnabled) as? Bool, true)
        XCTAssertEqual(persisted(target, AppSettings.Keys.aiAgentAllowCodeExecution) as? Bool, false)
        XCTAssertEqual(persisted(target, "sandbox.script.1234") as? Bool, false)
    }

    func testExportNeverContainsSecurityOrSecretKeys() throws {
        let defaults = scratch()
        for key in SettingsPaneID.allExportableKeys { defaults.set("v", forKey: key) }
        defaults.set(true, forKey: "sandbox.script.1234")
        defaults.set("tok", forKey: "mcpBearerToken")
        let porter = SettingsPreferencesPorter(knownKeys: SettingsPaneID.allExportableKeys)
        let text = String(decoding: try porter.export(from: defaults), as: UTF8.self)
        XCTAssertFalse(text.contains("sandbox.script"))
        XCTAssertFalse(text.contains("mcpBearerToken"))
        XCTAssertFalse(text.lowercased().contains("apikey"))
    }

    // MARK: Grid column migration

    func testMigrationAdoptsExplicitLegacyColumns() {
        let defaults = scratch()
        defaults.set(3, forKey: AppSettings.Keys.clipColumns)
        let domain = defaults.persistentDomain(forName: suiteName(of: defaults))
        XCTAssertEqual(GridColumnMigration.migratedMode(defaults: defaults, persistentDomain: domain), .fixed(3))
    }

    func testMigrationSkipsWhenNothingStoredOrModeAlreadyChosen() {
        let untouched = scratch()
        XCTAssertNil(GridColumnMigration.migratedMode(
            defaults: untouched, persistentDomain: untouched.persistentDomain(forName: suiteName(of: untouched))))
        let chosen = scratch()
        chosen.set(4, forKey: AppSettings.Keys.clipColumns)
        chosen.set("auto", forKey: GridPreferences.columnModeKey)
        XCTAssertNil(GridColumnMigration.migratedMode(
            defaults: chosen, persistentDomain: chosen.persistentDomain(forName: suiteName(of: chosen))))
    }

    @MainActor
    func testMigrationRunsOnceAndWritesFlag() {
        let defaults = scratch()
        defaults.set(2, forKey: AppSettings.Keys.clipColumns)
        let preferences = GridPreferences(defaults: defaults)
        XCTAssertEqual(preferences.columnMode, .auto)
        GridColumnMigration.run(defaults: defaults, domainName: suiteName(of: defaults), preferences: preferences)
        XCTAssertEqual(preferences.columnMode, .fixed(2))
        preferences.columnMode = .auto
        GridColumnMigration.run(defaults: defaults, domainName: suiteName(of: defaults), preferences: preferences)
        XCTAssertEqual(preferences.columnMode, .auto, "second run must not override the user's later choice")
        XCTAssertEqual(persisted(defaults, GridColumnMigration.migratedKey) as? Bool, true)
    }
}
