import XCTest
@testable import Clippy

final class RetentionServiceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeService(_ database: ClipDatabase, sensitive: @escaping (Clip) -> Bool = { _ in false }) -> (RetentionService, AuditLog) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-retention-audit-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let audit = AuditLog(directory: dir)
        let suiteName = "clippy-retention-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let service = RetentionService(
            database: database,
            preferences: RetentionPreferences(defaults: suite, managed: .none),
            audit: audit,
            now: { [now] in now },
            isSensitive: sensitive
        )
        return (service, audit)
    }

    private func days(_ count: Double) -> Date { now.addingTimeInterval(-count * 86_400) }

    @discardableResult
    private func save(_ database: ClipDatabase, _ text: String, age: Double, app: String = "com.example.test") throws -> Int64 {
        var clip = makeTextClip(text, createdAt: days(age))
        clip.sourceAppBundleID = app
        try database.saveCapturedClip(&clip, cap: 1000)
        return try XCTUnwrap(clip.id)
    }

    private func existingIDs(_ database: ClipDatabase) throws -> Set<Int64> {
        Set(try database.allClips().compactMap(\.id))
    }

    func testPreviewListsOnlyExpiredClipsAndDoesNotDelete() throws {
        let database = try makeTestDatabase(self)
        let old = try save(database, "old", age: 40)
        let fresh = try save(database, "fresh", age: 5)
        let (service, _) = makeService(database)
        var rules = RetentionRules()
        rules.forgetAfterDays = 30
        let candidates = try service.preview(rules: rules)
        XCTAssertEqual(candidates.map(\.clipID), [old])
        XCTAssertEqual(candidates.first?.reason, .forgetAfter)
        XCTAssertEqual(try existingIDs(database), [old, fresh])
    }

    func testApplyDeletesExpiredAndWritesAuditWithIDsOnly() throws {
        let database = try makeTestDatabase(self)
        let old = try save(database, "secret-ish body text", age: 40)
        let fresh = try save(database, "fresh", age: 1)
        let (service, audit) = makeService(database)
        var rules = RetentionRules()
        rules.isEnabled = true
        rules.forgetAfterDays = 30
        let result = try service.apply(rules: rules)
        XCTAssertEqual(result.deleted, [old])
        XCTAssertEqual(try existingIDs(database), [fresh])
        let entries = audit.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].entry.clipIDs, [old])
        XCTAssertEqual(entries[0].entry.action, "retention.expire")
        XCTAssertFalse(entries[0].entry.detail.contains("secret"))
        XCTAssertTrue(audit.verify().isValid)
    }

    func testDisabledRulesNeverDelete() throws {
        let database = try makeTestDatabase(self)
        let old = try save(database, "old", age: 400)
        let (service, audit) = makeService(database)
        var rules = RetentionRules()
        rules.forgetAfterDays = 1
        XCTAssertEqual(try service.apply(rules: rules), RetentionService.Result(deleted: [], failed: []))
        XCTAssertEqual(try existingIDs(database), [old])
        XCTAssertTrue(audit.allEntries().isEmpty)
    }

    func testPinnedClipsSurviveUnlessRuleIncludesThem() throws {
        let database = try makeTestDatabase(self)
        let pinned = try save(database, "pinned old", age: 90)
        let loose = try save(database, "loose old", age: 90)
        try database.toggleStarterMembership(clipID: pinned)
        let (service, _) = makeService(database)
        var rules = RetentionRules()
        rules.isEnabled = true
        rules.forgetAfterDays = 30
        XCTAssertEqual(try service.preview(rules: rules).map(\.clipID), [loose])
        rules.includeCategorized = true
        XCTAssertEqual(Set(try service.preview(rules: rules).map(\.clipID)), [pinned, loose])
    }

    func testPerKindAndPerAppRulesUseTheShortestApplicableTTL() throws {
        let database = try makeTestDatabase(self)
        let slack = try save(database, "from slack", age: 3, app: "com.tinyspeck.slackmacgap")
        let other = try save(database, "from elsewhere", age: 3)
        let (service, _) = makeService(database)
        var rules = RetentionRules()
        rules.forgetAfterDays = 30
        rules.appTTLDays = ["com.tinyspeck.slackmacgap": 2]
        let candidates = try service.preview(rules: rules)
        XCTAssertEqual(candidates.map(\.clipID), [slack])
        XCTAssertEqual(candidates.first?.reason, .app)

        rules = RetentionRules()
        rules.kindTTLDays = ["text": 1, "image": 100]
        XCTAssertEqual(Set(try service.preview(rules: rules).map(\.clipID)), [slack, other])
    }

    func testSensitiveClipsExpireByHoursWhileOthersStay() throws {
        let database = try makeTestDatabase(self)
        let card = try save(database, "4111 card", age: 0.5)   // 12 hours old
        let note = try save(database, "plain note", age: 0.5)
        let (service, _) = makeService(database, sensitive: { $0.contentText.contains("card") })
        var rules = RetentionRules()
        rules.sensitiveTTLHours = 6
        let candidates = try service.preview(rules: rules)
        XCTAssertEqual(candidates.map(\.clipID), [card])
        XCTAssertEqual(candidates.first?.reason, .sensitive)
        XCTAssertNotEqual(candidates.first?.clipID, note)

        rules.sensitiveTTLHours = 24
        XCTAssertTrue(try service.preview(rules: rules).isEmpty, "not old enough yet")
    }

    func testExplicitSensitiveRuleCanExpirePinnedClipsWhenIncluded() throws {
        let database = try makeTestDatabase(self)
        let pinnedCard = try save(database, "card pinned", age: 2)
        try database.toggleStarterMembership(clipID: pinnedCard)
        let (service, _) = makeService(database, sensitive: { $0.contentText.contains("card") })
        var rules = RetentionRules()
        rules.sensitiveTTLHours = 1
        XCTAssertTrue(try service.preview(rules: rules).isEmpty)
        rules.includeCategorized = true
        XCTAssertEqual(try service.preview(rules: rules).map(\.clipID), [pinnedCard])
    }

    func testTTLSelectionIgnoresNegativeValues() {
        var rules = RetentionRules()
        rules.forgetAfterDays = -5
        XCTAssertNil(rules.ttl(kind: .text, bundleID: nil, isSensitive: false))
    }
}
