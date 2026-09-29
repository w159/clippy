import XCTest
@testable import Clippy

final class AutoFileTests: XCTestCase {
    private func vec(_ values: [Float], _ language: String = "en") -> LanguageVector {
        LanguageVector(vector: values, language: language)
    }

    func testCentroidIsMeanAndRespectsMinMembers() {
        let centroids = AutoFileScoring.centroids(
            members: [1: [vec([1, 0]), vec([3, 0]), vec([2, 3])], 2: [vec([1, 1]), vec([1, 1])]], minMembers: 3)
        XCTAssertEqual(centroids.map(\.categoryID), [1])
        XCTAssertEqual(centroids[0].vector, [2, 1])
        XCTAssertEqual(centroids[0].memberCount, 3)
    }

    func testCentroidUsesDominantLanguageOnly() {
        let centroids = AutoFileScoring.centroids(
            members: [1: [vec([1, 0]), vec([1, 0]), vec([0, 5], "fr")]], minMembers: 2)
        XCTAssertEqual(centroids.first?.language, "en")
        XCTAssertEqual(centroids.first?.vector, [1, 0])
    }

    func testSimilarityFloorLanguageAndExclusion() {
        let near = CategoryCentroid(categoryID: 1, vector: [1, 0], language: "en", memberCount: 3)
        let far = CategoryCentroid(categoryID: 2, vector: [0, 1], language: "en", memberCount: 3)
        let other = CategoryCentroid(categoryID: 3, vector: [1, 0], language: "fr", memberCount: 3)
        let hits = AutoFileScoring.ranked(vec([1, 0.1]), against: [far, near, other], floor: 0.5)
        XCTAssertEqual(hits.map(\.categoryID), [1])
        XCTAssertTrue(AutoFileScoring.ranked(vec([1, 0.1]), against: [near], floor: 0.5, excluding: [1]).isEmpty)
        XCTAssertTrue(AutoFileScoring.ranked(vec([1, 0.1]), against: [near], floor: 0.999).isEmpty)
    }

    func testDismissalIsPerPairAndReversible() {
        let store = AutoFileDismissals(fileURL: nil)
        store.dismiss(contentKey: "abc", categoryID: 1)
        XCTAssertTrue(store.isDismissed(contentKey: "abc", categoryID: 1))
        XCTAssertFalse(store.isDismissed(contentKey: "abc", categoryID: 2))
        XCTAssertFalse(store.isDismissed(contentKey: "xyz", categoryID: 1))
        XCTAssertEqual(store.dismissedCategories(contentKey: "abc"), [1])
        store.restore(contentKey: "abc", categoryID: 1)
        XCTAssertFalse(store.isDismissed(contentKey: "abc", categoryID: 1))
    }

    func testDismissalsPersistToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autofile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        AutoFileDismissals(fileURL: url).dismiss(contentKey: "k", categoryID: 4)
        XCTAssertTrue(AutoFileDismissals(fileURL: url).isDismissed(contentKey: "k", categoryID: 4))
    }

    private struct Source: AutoFileDataSource {
        func categories() -> [AutoFileCategory] { [AutoFileCategory(id: 1, name: "Receipts")] }
        func filedClips(inCategory id: Int64) -> [AutoFileClip] {
            (0..<3).map { AutoFileClip(id: Int64($0), contentKey: "f\($0)", text: "aaa", isSensitive: false) }
                + [AutoFileClip(id: 9, contentKey: "s", text: "dddd", isSensitive: true)]
        }
        func recentUncategorized(limit: Int) -> [AutoFileClip] {
            [AutoFileClip(id: 20, contentKey: "u", text: "aaaa", isSensitive: false),
             AutoFileClip(id: 21, contentKey: "v", text: "aaaa", isSensitive: true)]
        }
    }

    private struct Letters: TextEmbedder {
        func vector(for text: String) -> [Float]? {
            let counts = "ad".map { letter in Float(text.lowercased().filter { $0 == letter }.count) }
            return counts.contains { $0 > 0 } ? counts : nil
        }
    }

    func testSuggesterSkipsSensitiveDismissedAndNeverFilesItself() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "autofile-\(UUID().uuidString)"))
        let prefs = SemanticSearchPreferences(defaults: suite)
        let dismissals = AutoFileDismissals(fileURL: nil)
        let suggester = AutoFileSuggester(embedder: Letters(), source: Source(), dismissals: dismissals, preferences: prefs)
        XCTAssertTrue(suggester.suggestForRecentUncategorized(limit: 5).isEmpty, "off by default")
        prefs.isAutoFileEnabled = true
        let found = suggester.suggestForRecentUncategorized(limit: 5)
        XCTAssertEqual(found.map(\.clipID), [20])
        XCTAssertEqual(found.first?.categoryID, 1)
        var filed: [(Int64, Int64)] = []
        suggester.dismiss(found[0], contentKey: "u")
        XCTAssertTrue(filed.isEmpty)
        XCTAssertTrue(suggester.suggestForRecentUncategorized(limit: 5).isEmpty)
        suggester.accept(found[0]) { filed.append(($0, $1)) }
        XCTAssertEqual(filed.count, 1)
    }
}
