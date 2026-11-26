import XCTest
@testable import Clippy

/// A window that lists one id twice (a racing capture or a stale decode) must not crash the store.
/// The class name sorts last so that, on a build without the fix, the crash comes after every other test ran.
@MainActor
final class ZDuplicateIDWindowTests: XCTestCase {
    private func clip(_ id: Int64, _ text: String) -> Clip {
        var clip = makeTextClip(text)
        clip.id = id
        return clip
    }

    /// Seeded fault: `Dictionary(uniqueKeysWithValues:)` trapped on the repeated id, which closed the app.
    func testDuplicateIDsInTheObservedWindowDoNotTrap() throws {
        let db = try makeTestDatabase(self)
        let store = ClipStore(database: db)
        let first = clip(7, "alpha one")
        let second = clip(7, "alpha two")
        store.recents = [first, second]
        XCTAssertEqual(store.recentsByID[7]?.contentText, "alpha one", "the first clip wins")

        store.query = "alpha"
        store.recents = [first, second, clip(8, "alpha three")]
        XCTAssertEqual(store.recentsByID.count, 2)
        store.categoryClipOrder = [3: [7, 7, 8]]
        _ = store.clipsForCategory(3)
    }
}
