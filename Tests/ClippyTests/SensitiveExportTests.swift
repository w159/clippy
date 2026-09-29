import XCTest
@testable import Clippy

final class SensitiveExportTests: XCTestCase {

    private func pinned(_ database: ClipDatabase, _ text: String) throws {
        var clip = makeTextClip(text)
        try database.saveCapturedClip(&clip, cap: 100)
        try database.toggleStarterMembership(clipID: try XCTUnwrap(clip.id))
    }

    func testSensitiveClipsAreLeftOutOfTheExportByDefault() throws {
        let database = try makeTestDatabase(self)
        try pinned(database, "meeting agenda")
        try pinned(database, "client account 12345")
        let groups = try database.clipsGroupedByCategory(isSensitive: { $0.contentText.contains("account") })
        XCTAssertEqual(groups.flatMap(\.clips).map(\.contentText), ["meeting agenda"])
    }

    func testFullBackupCanIncludeSensitiveClipsExplicitly() throws {
        let database = try makeTestDatabase(self)
        try pinned(database, "client account 12345")
        let groups = try database.clipsGroupedByCategory(excludingSensitive: false, isSensitive: { _ in true })
        XCTAssertEqual(groups.flatMap(\.clips).count, 1)
    }

    func testCategoriesSurviveEvenWhenAllTheirClipsAreWithheld() throws {
        let database = try makeTestDatabase(self)
        try pinned(database, "only sensitive")
        let groups = try database.clipsGroupedByCategory(isSensitive: { _ in true })
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].clips.isEmpty)
    }
}
