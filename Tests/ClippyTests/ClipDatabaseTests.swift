import XCTest
@testable import Clippy

@MainActor
final class ClipDatabaseTests: XCTestCase {
    func testOpensAtInjectedURL() throws {
        let db = try makeTestDatabase(self)
        XCTAssertTrue(db.databaseURL.path.contains("clippy-tests-"))
        var clip = makeTextClip("hello")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testTextDedupePrefixUsesSQLiteCharacterBoundary() throws {
        let db = try makeTestDatabase(self)
        let text = String(repeating: "a", count: 63) + "e\u{301}" + String(repeating: "z", count: 10)
        var first = makeTextClip(text)
        var duplicate = makeTextClip(text)
        try db.saveCapturedClip(&first, cap: 100)
        try db.saveCapturedClip(&duplicate, cap: 100)
        XCTAssertEqual(try db.allClips().count, 1)
    }
}
