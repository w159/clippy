import XCTest
@testable import Clippy

@MainActor
final class SnippetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var fileURL: URL { directory.appendingPathComponent("snippets.json") }

    func testRoundTripPersistsAllFields() throws {
        let original = Snippet(abbreviation: ";sig", title: "Sig", body: "Best,\n{fill:Name}", folder: "Mail", tags: ["a", "b"],
                               isEnabled: false, useCount: 3, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try SnippetStore(fileURL: fileURL).add(original)
        let reloaded = SnippetStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.snippets, [original])
        XCTAssertEqual(reloaded.folders, ["Mail"])
    }

    func testUpdateDeleteDuplicateAndUse() throws {
        let store = SnippetStore(fileURL: fileURL)
        var item = Snippet(abbreviation: ";a", title: "A", body: "b")
        try store.add(item)
        item.body = "changed"
        try store.update(item)
        let copy = try XCTUnwrap(store.duplicate(id: item.id))
        XCTAssertEqual(copy.abbreviation, "")
        XCTAssertEqual(copy.title, "A copy")
        store.recordUse(id: item.id)
        XCTAssertEqual(SnippetStore(fileURL: fileURL).snippets.first { $0.id == item.id }?.useCount, 1)
        try store.delete(id: item.id)
        XCTAssertEqual(SnippetStore(fileURL: fileURL).snippets.map(\.id), [copy.id])
    }

    func testLossyDecodeKeepsGoodEntriesAndDefaultsMissingFields() throws {
        let good = UUID()
        let json = "[{\"id\":\"\(good.uuidString)\",\"abbreviation\":\";x\"},{\"broken\":true}]"
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = SnippetStore(fileURL: fileURL)
        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets[0].abbreviation, ";x")
        XCTAssertTrue(store.snippets[0].isEnabled)
        XCTAssertNil(store.loadError)
    }

    func testCorruptFileIsQuarantinedNotOverwritten() throws {
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = SnippetStore(fileURL: fileURL)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.add(Snippet(abbreviation: ";a")))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.contains("corrupt") })
    }

    func testImportExportSkipsDuplicateAbbreviations() throws {
        let source = SnippetStore(fileURL: fileURL)
        try source.add(Snippet(abbreviation: ";a", title: "A", body: "1"))
        try source.add(Snippet(abbreviation: ";b", title: "B", body: "2"))
        let data = try source.exportJSON()
        let target = SnippetStore(fileURL: directory.appendingPathComponent("other.json"))
        try target.add(Snippet(abbreviation: ";a", title: "Existing"))
        XCTAssertEqual(try target.importJSON(data), 1)
        XCTAssertEqual(target.snippets.map(\.abbreviation).sorted(), [";a", ";b"])
        XCTAssertNotEqual(target.snippets.last?.id, source.snippets.last?.id)
        XCTAssertThrowsError(try target.importJSON(Data("nope".utf8)))
    }
}
