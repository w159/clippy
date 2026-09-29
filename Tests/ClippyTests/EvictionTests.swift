import XCTest
@testable import Clippy

@MainActor
final class EvictionTests: XCTestCase {
    /// Categorized clips are exempt from the history cap.
    func testCapEvictionSkipsCategorizedClips() throws {
        let db = try makeTestDatabase(self)

        var old = makeTextClip("oldest", createdAt: Date(timeIntervalSinceNow: -300))
        try db.saveCapturedClip(&old, cap: 2)
        let oldID = try XCTUnwrap(db.allClips().first?.id)
        try db.toggleStarterMembership(clipID: oldID)

        for i in 0..<3 {
            var clip = makeTextClip("clip-\(i)", createdAt: Date(timeIntervalSinceNow: Double(i - 3)))
            try db.saveCapturedClip(&clip, cap: 2)
        }

        let texts = try db.allClips().map(\.contentText)
        XCTAssertTrue(texts.contains("oldest"), "categorized clip must survive the cap")
        XCTAssertEqual(texts.count, 3) // 2 uncategorized + 1 categorized
    }

    func testDeleteUnclassifiedKeepsCategorized() throws {
        let db = try makeTestDatabase(self)
        var keep = makeTextClip("keep")
        try db.saveCapturedClip(&keep, cap: AppSettings.shared.maxHistoryItems)
        var drop = makeTextClip("drop")
        try db.saveCapturedClip(&drop, cap: AppSettings.shared.maxHistoryItems)
        let keepID = try XCTUnwrap(db.allClips().first(where: { $0.contentText == "keep" })?.id)
        try db.toggleStarterMembership(clipID: keepID)

        try db.deleteUnclassifiedClips()
        XCTAssertEqual(try db.allClips().map(\.contentText), ["keep"])
    }
}
