import GRDB
import XCTest
@testable import Clippy

/// Database-level search behavior that used to be wrong or throw: quoted
/// phrases with punctuation, very long pasted queries, and the two-tier read.
final class SearchRobustnessTests: XCTestCase {
    @discardableResult
    private func add(_ db: ClipDatabase, _ text: String, at date: Date = Date()) throws -> Int64 {
        var clip = makeTextClip(text, createdAt: date)
        try db.saveCapturedClip(&clip, cap: 10_000)
        return try db.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM clips")! }
    }

    private func texts(_ db: ClipDatabase, _ query: String, limit: Int = 50) throws -> [String] {
        try db.search(matching: query, limit: limit).clips.map(\.contentText)
    }

    // MARK: - Quoted phrases with punctuation

    /// Seeded fault: `FTS5Pattern(matchingPhrase: "c++")` tokenizes to the phrase `c`,
    /// so the quoted query matched every clip with the word C and ranked it first.
    func testQuotedPhraseWithPunctuationMatchesLiterally() throws {
        let db = try makeTestDatabase(self)
        try add(db, "C++ templates")
        try add(db, "c sharp notes")
        try add(db, "plain c word")
        XCTAssertEqual(try texts(db, "\"c++\""), ["C++ templates"])
        XCTAssertEqual(Set(try texts(db, "-\"c++\"")), ["c sharp notes", "plain c word"])
    }

    /// Seeded fault: `"user_name"` tokenizes to the phrase `user name`.
    func testQuotedPhraseWithUnderscoreDoesNotMatchTheSplitWords() throws {
        let db = try makeTestDatabase(self)
        let base = Date().addingTimeInterval(-1000)
        try add(db, "my user_name variable", at: base)
        try add(db, "the user name field", at: base.addingTimeInterval(10))
        XCTAssertEqual(try texts(db, "\"user_name\""), ["my user_name variable"])
    }

    func testQuotedPhraseOfPlainWordsStillUsesTheWordIndex() throws {
        let db = try makeTestDatabase(self)
        try add(db, "wire transfer approved")
        try add(db, "transfer wire draft")
        XCTAssertEqual(try texts(db, "\"wire transfer\""), ["wire transfer approved"])
    }

    // MARK: - Long queries

    /// Seeded fault: 1000 words put 1000 ANDed clauses in one statement and SQLite
    /// threw "Expression tree is too large".
    func testThousandWordQueryWorks() throws {
        let db = try makeTestDatabase(self)
        let words = (0..<1000).map { "tok\($0)" }
        let base = Date().addingTimeInterval(-1000)
        try add(db, words.joined(separator: " "), at: base)
        try add(db, words.dropLast().joined(separator: " "), at: base.addingTimeInterval(10))
        try add(db, "tok0 tok1 tok2", at: base.addingTimeInterval(20))
        // Only the first clip has the last word: the words past the SQL cap are
        // still enforced.
        XCTAssertEqual(try texts(db, words.joined(separator: " ")), [words.joined(separator: " ")])
    }

    /// Words past the SQL cap are enforced in Swift, negated ones included: the
    /// only clip that must be hidden here contains just the last negated word.
    func testSurplusPositiveAndNegatedWordsAreStillEnforced() throws {
        let db = try makeTestDatabase(self)
        // Fixed-length words so none is a prefix or fragment of another.
        func word(_ prefix: String, _ index: Int) -> String {
            prefix + String(UnicodeScalar(UInt8(97 + index))) + "x"
        }
        let positives = (0..<20).map { word("pos", $0) }
        let negatives = (0..<20).map { word("neg", $0) }
        let base = Date().addingTimeInterval(-1000)
        try add(db, positives.joined(separator: " "), at: base)
        try add(db, positives.joined(separator: " ") + " " + negatives[19], at: base.addingTimeInterval(10))
        try add(db, positives.dropLast().joined(separator: " "), at: base.addingTimeInterval(20))
        let query = positives.joined(separator: " ") + " " + negatives.map { "-" + $0 }.joined(separator: " ")
        XCTAssertEqual(try texts(db, query), [positives.joined(separator: " ")])
    }

    /// Seeded fault: a 60,000 byte word became a LIKE pattern over SQLite's 50,000 byte limit.
    func testSingleHugeWordQueryWorksAndIsMatchedInFull() throws {
        let db = try makeTestDatabase(self)
        let huge = String(repeating: "x", count: 60_000)
        let base = Date().addingTimeInterval(-1000)
        try add(db, "has \(huge) inside", at: base)
        try add(db, "only a prefix \(String(repeating: "x", count: 600))", at: base.addingTimeInterval(10))
        XCTAssertEqual(try texts(db, huge), ["has \(huge) inside"])
        // The same word negated keeps the clip that only shares its prefix.
        XCTAssertEqual(try texts(db, "inside -\(huge)"), [])
        XCTAssertEqual(try texts(db, "prefix -\(huge)"), ["only a prefix \(String(repeating: "x", count: 600))"])
    }

    // MARK: - Two-tier read

    /// Whole-word matches come first, then fragments, newest first in each tier, and paging crosses
    /// the boundary without repeating or skipping a clip.
    func testTiersAreOrderedAndPagedAcrossTheBoundary() throws {
        let db = try makeTestDatabase(self)
        let base = Date().addingTimeInterval(-10_000)
        var expected: [String] = []
        for index in 0..<5 {
            // Older word matches, newer fragment matches: recency alone would interleave them.
            try add(db, "invoice word \(index)", at: base.addingTimeInterval(Double(index)))
            try add(db, "reinvoiced fragment \(index)", at: base.addingTimeInterval(100 + Double(index)))
        }
        expected += (0..<5).reversed().map { "invoice word \($0)" }
        expected += (0..<5).reversed().map { "reinvoiced fragment \($0)" }
        XCTAssertEqual(try texts(db, "invoice", limit: 50), expected)
        XCTAssertEqual(try texts(db, "invoice", limit: 7), Array(expected.prefix(7)))
        XCTAssertEqual(try texts(db, "invoice", limit: 3), Array(expected.prefix(3)))
        // The derived-kind path pages in blocks of at least 200; the order must match.
        XCTAssertEqual(try texts(db, "invoice -#link", limit: 50), expected)
    }
}
