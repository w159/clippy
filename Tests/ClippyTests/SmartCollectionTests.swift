import XCTest
@testable import Clippy

final class SmartCollectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func add(_ db: ClipDatabase, _ text: String, app: String = "Notes", daysAgo: Double = 0,
                     kind: ClipContentKind = .text, media: String? = nil) throws {
        var clip = Clip(id: nil, contentText: text, contentRTF: nil, contentHTML: nil, typeIdentifier: "public.utf8-plain-text",
                        sourceAppBundleID: "com.test.\(app.lowercased())", sourceAppName: app,
                        createdAt: now.addingTimeInterval(-daysAgo * 86_400), contentKind: kind,
                        mediaFilename: media, thumbFilename: media)
        if kind == .image { try db.saveCapturedImageClip(&clip, cap: 100) } else { try db.saveCapturedClip(&clip, cap: 100) }
    }

    private func names(_ clips: [Clip]) -> [String] { clips.map(\.contentText) }

    func testCRUDAndOrdering() throws {
        let db = try makeTestDatabase(self)
        let one = try db.createSmartCollection(name: " Links ", rule: SmartCollectionRule(kinds: [.link]))
        let two = try db.createSmartCollection(name: "Old", rule: SmartCollectionRule(olderThanDays: 30))
        XCTAssertEqual(one.name, "Links")
        XCTAssertEqual(try db.smartCollections().map(\.name), ["Links", "Old"])
        try db.reorderSmartCollections(ids: [two.id!])
        XCTAssertEqual(try db.smartCollections().map(\.name), ["Old", "Links"])
        try db.updateSmartCollection(id: one.id!, name: "URLs", rule: SmartCollectionRule(kinds: [.link], sourceApp: "safari"))
        XCTAssertEqual(try db.smartCollections().last?.rule.sourceApp, "safari")
        try db.deleteSmartCollection(id: two.id!)
        XCTAssertEqual(try db.smartCollections().count, 1)
        XCTAssertThrowsError(try db.updateSmartCollection(id: 999, name: "x", rule: SmartCollectionRule(kinds: [.text]))) {
            XCTAssertEqual($0 as? SmartCollectionError, .notFound)
        }
    }

    func testValidation() throws {
        let db = try makeTestDatabase(self)
        func fail(_ name: String, _ rule: SmartCollectionRule, _ expected: SmartCollectionError) {
            XCTAssertThrowsError(try db.createSmartCollection(name: name, rule: rule)) {
                XCTAssertEqual($0 as? SmartCollectionError, expected)
            }
        }
        fail("  ", SmartCollectionRule(kinds: [.text]), .emptyName)
        fail("Empty", SmartCollectionRule(), .emptyRule)
        fail("Bad", SmartCollectionRule(textPattern: "([unclosed"), .invalidPattern)
        fail("Days", SmartCollectionRule(olderThanDays: -1), .invalidDays)
    }

    func testRuleEvaluation() throws {
        let db = try makeTestDatabase(self)
        try add(db, "https://apple.com", app: "Safari", daysAgo: 1)
        try add(db, "https://old.example", app: "Safari", daysAgo: 60)
        try add(db, "plain note", app: "Notes", daysAgo: 2)
        try add(db, "INV-1234 due", app: "Mail", daysAgo: 3)
        try add(db, "", app: "Shots", daysAgo: 4, kind: .image, media: "s.png")
        func run(_ rule: SmartCollectionRule) throws -> [String] {
            names(try db.clips(matching: rule, limit: 50, now: now, sensitiveStore: nil))
        }
        XCTAssertEqual(try run(SmartCollectionRule(kinds: [.link])), ["https://apple.com", "https://old.example"])
        XCTAssertEqual(try run(SmartCollectionRule(kinds: [.link], newerThanDays: 30)), ["https://apple.com"])
        XCTAssertEqual(try run(SmartCollectionRule(olderThanDays: 30)), ["https://old.example"])
        XCTAssertEqual(try run(SmartCollectionRule(sourceApp: "MAIL")), ["INV-1234 due"])
        XCTAssertEqual(try run(SmartCollectionRule(textPattern: #"inv-\d{4}"#)), ["INV-1234 due"])
        XCTAssertEqual(try run(SmartCollectionRule(kinds: [.image])), [""])
        XCTAssertEqual(try run(SmartCollectionRule(kinds: [.link], sourceApp: "safari", olderThanDays: 30)), ["https://old.example"])
    }

    func testRegexAlsoMatchesOCRText() throws {
        let db = try makeTestDatabase(self)
        try add(db, "", kind: .image, media: "r.png")
        let id = try XCTUnwrap(try db.allClips().first?.id)
        try db.setOCRText(id: id, text: "Total: $42.00")
        XCTAssertEqual(try db.clips(matching: SmartCollectionRule(textPattern: #"\$\d+\.\d\d"#), limit: 5, now: now).count, 1)
    }

    func testSensitiveFlagFiltering() throws {
        let db = try makeTestDatabase(self)
        try add(db, "my card 4111 1111 1111 1111 exp 12/29")
        try add(db, "hello world")
        let store = SensitiveFlagStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("flags-\(UUID().uuidString)"))
        let only = try db.clips(matching: SmartCollectionRule(sensitive: true), limit: 10, now: now, sensitiveStore: store)
        let rest = try db.clips(matching: SmartCollectionRule(sensitive: false), limit: 10, now: now, sensitiveStore: store)
        XCTAssertEqual(only.count + rest.count, 2)
        XCTAssertEqual(rest.map(\.contentText), ["hello world"])
    }

    func testEvaluationPagesUntilLimit() throws {
        let db = try makeTestDatabase(self)
        try db.dbQueue.write { conn in
            for index in 0..<450 {
                try conn.execute(sql: """
                    INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                    VALUES (?, 'public.utf8-plain-text', ?, 'text')
                    """, arguments: [index == 0 ? "needle" : "hay \(index)", now.addingTimeInterval(Double(-index))])
            }
        }
        XCTAssertEqual(try db.clips(matching: SmartCollectionRule(textPattern: "needle"), limit: 1, now: now).count, 1)
        XCTAssertEqual(try db.clips(matching: SmartCollectionRule(textPattern: "hay"), limit: 400, now: now).count, 400)
    }
}
