import GRDB
import XCTest
@testable import Clippy

/// The list queries stay on the createdAt index: search tier 1 stops at the page
/// size and the window stamps never sort in a temp b-tree.
final class QueryPlanTests: CaptureTestCase {
    private func planText(_ db: ClipDatabase, sql: String, arguments: [DatabaseValueConvertible]) throws -> String {
        try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: "EXPLAIN QUERY PLAN " + sql, arguments: StatementArguments(arguments))
                .map { $0["detail"] as String }
                .joined(separator: "\n")
        }
    }

    private func seed(_ db: ClipDatabase) throws {
        for index in 0..<20 {
            var clip = makeTextClip("invoice number \(index)", createdAt: Date().addingTimeInterval(-Double(index)))
            try db.saveCapturedClip(&clip, cap: 1_000)
        }
    }

    func testSearchFirstTierWalksTheCreatedAtIndex() throws {
        let db = try makeTestDatabase(self)
        try seed(db)
        let tier = try db.dbQueue.read { conn -> ClipDatabase.SearchStatement in
            var warnings: [QueryWarning] = []
            let parsed = ClipQueryParser.parse("invoice", now: Date(), calendar: .current)
            return try ClipDatabase.plan(parsed, db: conn, warnings: &warnings).tiers[0]
        }
        let text = try planText(
            db, sql: tier.sql + " LIMIT ? OFFSET ?",
            arguments: tier.arguments + [50 as DatabaseValueConvertible, 0])
        XCTAssertTrue(text.contains("clips_on_createdAt"), text)
        XCTAssertFalse(text.contains("TEMP B-TREE"), text)
    }

    func testWindowStampsUseTheCreatedAtIndexWithoutASort() throws {
        let db = try makeTestDatabase(self)
        try seed(db)
        let text = try planText(db, sql: ClipWindowLoader.stampsSQL, arguments: [300])
        XCTAssertTrue(text.contains("clips_on_createdAt"), text)
        XCTAssertFalse(text.contains("TEMP B-TREE FOR ORDER BY"), text)
    }

    func testHasRichContentFollowsTheStoredBlobs() throws {
        let db = try makeTestDatabase(self)
        var rtfOnly = makeTextClip("invoice rtf")
        rtfOnly.contentRTF = Data("{\\rtf1 x}".utf8)
        var htmlOnly = makeTextClip("invoice html")
        htmlOnly.contentHTML = Data("<b>x</b>".utf8)
        var plain = makeTextClip("invoice plain")
        for index in 0..<3 {
            switch index {
            case 0: try db.saveCapturedClip(&rtfOnly, cap: 1_000)
            case 1: try db.saveCapturedClip(&htmlOnly, cap: 1_000)
            default: try db.saveCapturedClip(&plain, cap: 1_000)
            }
        }
        let hits = try db.search(matching: "invoice", limit: 10).clips
        func rich(_ id: Int64?) throws -> Bool {
            try XCTUnwrap(hits.first { $0.id == id }).hasRichContent
        }
        XCTAssertTrue(try rich(rtfOnly.id))
        XCTAssertTrue(try rich(htmlOnly.id))
        XCTAssertFalse(try rich(plain.id))
    }
}
