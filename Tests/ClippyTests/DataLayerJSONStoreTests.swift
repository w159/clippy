import XCTest
@testable import Clippy

private struct Item: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
}

/// DAT-01/02 and the SCR-07 lossy strategy.
final class DataLayerJSONStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private var file: URL { dir.appendingPathComponent("items.json") }

    private func corruptSiblings() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    func testDecodeFailurePreservesBytesReportsErrorAndRefusesToSave() throws {
        let garbage = Data("{ definitely not [json".utf8)
        try garbage.write(to: file)

        let store = JSONFileStore<Item>(fileURL: file)
        XCTAssertTrue(store.items.isEmpty)
        guard case .corrupt(_, let moved)? = store.loadError else { return XCTFail("loadError not set") }
        let quarantined = try XCTUnwrap(moved)
        XCTAssertEqual(try Data(contentsOf: quarantined), garbage, "bytes preserved exactly")
        XCTAssertTrue(quarantined.lastPathComponent.contains(".corrupt-"))

        XCTAssertThrowsError(try store.tryAdd(Item(id: 1, name: "a"))) {
            XCTAssertEqual($0 as? JSONFileStoreError, .unresolvedLoadError)
        }
        XCTAssertTrue(store.items.isEmpty, "a refused save does not change memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing was written over the user's data")

        store.add(Item(id: 2, name: "b"))  // non-throwing path records instead of swallowing
        XCTAssertNotNil(store.saveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try store.resolveLoadError()
        XCTAssertNil(store.loadError)
        try store.tryAdd(Item(id: 3, name: "c"))
        XCTAssertEqual(JSONFileStore<Item>(fileURL: file).items, [Item(id: 3, name: "c")])
        XCTAssertEqual(try corruptSiblings().count, 1, "the corrupt copy is still there")
    }

    func testFailedSaveThrowsAndRollsBackMemory() throws {
        let unwritable = dir.appendingPathComponent("missing-dir/items.json")
        let store = JSONFileStore<Item>(fileURL: unwritable)
        XCTAssertThrowsError(try store.tryAdd(Item(id: 1, name: "a")))
        XCTAssertTrue(store.items.isEmpty, "memory must not claim a state the disk lacks")

        store.add(Item(id: 1, name: "a"))
        XCTAssertNotNil(store.saveError, "non-throwing mutators surface the failure")
    }

    func testSuccessfulSaveClearsSaveError() throws {
        let store = JSONFileStore<Item>(fileURL: file)
        try store.tryAdd(Item(id: 1, name: "a"))
        XCTAssertNil(store.saveError)
        XCTAssertEqual(try JSONDecoder().decode([Item].self, from: Data(contentsOf: file)).count, 1)
    }

    func testLossyStrategyKeepsGoodElementsAndBacksUpTheOriginal() throws {
        let json = #"[{"id":1,"name":"ok"},{"id":"bad"},{"id":3,"name":"also ok"}]"#
        try Data(json.utf8).write(to: file)

        let strict = JSONFileStore<Item>(fileURL: file)
        XCTAssertNotNil(strict.loadError, "strict mode rejects the whole file")
        try? FileManager.default.removeItem(at: dir)
        try setUpWithError()
        try Data(json.utf8).write(to: file)

        let lossy = JSONFileStore<Item>(fileURL: file, decodeStrategy: .lossy)
        XCTAssertNil(lossy.loadError)
        XCTAssertEqual(lossy.items.map(\.id), [1, 3])
        XCTAssertEqual(lossy.skippedElementCount, 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".lossy-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backups[0])), json)
    }

    func testLossyStrategyStillRejectsANonArrayFile() throws {
        try Data(#"{"not":"an array"}"#.utf8).write(to: file)
        let store = JSONFileStore<Item>(fileURL: file, decodeStrategy: .lossy)
        XCTAssertNotNil(store.loadError)
    }
}
