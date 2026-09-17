import XCTest
@testable import Clippy

// MARK: - Minimal fixture type

/// A lightweight Codable + Identifiable struct used solely to exercise
/// JSONFileStore without pulling in domain models that carry extra baggage.
private struct Stub: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var order: Int
}

// MARK: - Tests

final class JSONFileStoreTests: XCTestCase {

    // Gives each test a fresh file that is automatically deleted afterward.
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONFileStoreTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> JSONFileStore<Stub> {
        JSONFileStore<Stub>(fileURL: tempURL)
    }

    private func stub(_ name: String, order: Int = 0) -> Stub {
        Stub(id: UUID(), name: name, order: order)
    }

    // MARK: - add + reload

    func testAddPersistsAcrossReload() throws {
        let a = stub("alpha", order: 0)
        let b = stub("beta",  order: 1)

        let s1 = makeStore()
        s1.add(a)
        s1.add(b)

        // Reload from the same file.
        let s2 = makeStore()
        XCTAssertEqual(s2.items.count, 2)
        XCTAssertTrue(s2.items.contains(where: { $0.id == a.id }))
        XCTAssertTrue(s2.items.contains(where: { $0.id == b.id }))
    }

    // MARK: - update

    func testUpdatePersistsAcrossReload() throws {
        var a = stub("original")
        let s1 = makeStore()
        s1.add(a)

        a.name = "updated"
        s1.update(a)

        let s2 = makeStore()
        XCTAssertEqual(s2.items.first?.name, "updated")
    }

    // MARK: - delete

    func testDeletePersistsAcrossReload() throws {
        let a = stub("keep")
        let b = stub("remove")

        let s1 = makeStore()
        s1.add(a)
        s1.add(b)
        s1.delete(id: b.id)

        let s2 = makeStore()
        XCTAssertEqual(s2.items.count, 1)
        XCTAssertEqual(s2.items.first?.id, a.id)
    }

    // MARK: - move (array order)

    func testMoveReordersAndPersistsOrder() throws {
        let a = stub("A")
        let b = stub("B")
        let c = stub("C")

        let s1 = makeStore()
        s1.add(a)
        s1.add(b)
        s1.add(c)
        // Move C before B: expected order A, C, B
        s1.move(draggedID: c.id, before: b.id)

        let s2 = makeStore()
        XCTAssertEqual(s2.items.count, 3)
        XCTAssertEqual(s2.items[0].id, a.id)
        XCTAssertEqual(s2.items[1].id, c.id)
        XCTAssertEqual(s2.items[2].id, b.id)
    }

    // MARK: - move no-op guards

    func testMoveWithUnknownDraggedIDIsNoOp() throws {
        let a = stub("A")
        let b = stub("B")

        let s1 = makeStore()
        s1.add(a)
        s1.add(b)
        s1.move(draggedID: UUID(), before: b.id) // unknown dragged id

        XCTAssertEqual(s1.items.count, 2)
        XCTAssertEqual(s1.items[0].id, a.id)
    }

    func testMoveWithUnknownTargetIDIsNoOp() throws {
        let a = stub("A")
        let b = stub("B")

        let s1 = makeStore()
        s1.add(a)
        s1.add(b)
        s1.move(draggedID: a.id, before: UUID()) // unknown target id

        XCTAssertEqual(s1.items.count, 2)
        XCTAssertEqual(s1.items[0].id, a.id)
    }

    // MARK: - empty file loads cleanly

    func testLoadFromMissingFileYieldsEmptyItems() {
        // tempURL does not exist yet.
        let s = makeStore()
        XCTAssertEqual(s.items.count, 0)
    }

    // MARK: - configureDecoder / configureEncoder round-trip

    func testDateStrategyRoundTrip() throws {
        // Borrow Script's date fields by making a Codable stub with a Date.
        struct Dated: Codable, Identifiable, Equatable {
            var id: UUID
            var createdAt: Date
        }
        let dateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONFileStoreTests-dated-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dateURL) }

        let original = Dated(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000_000))

        let s1 = JSONFileStore<Dated>(
            fileURL: dateURL,
            configureEncoder: { $0.dateEncodingStrategy = .iso8601 },
            configureDecoder: { $0.dateDecodingStrategy = .iso8601 }
        )
        s1.add(original)

        let s2 = JSONFileStore<Dated>(
            fileURL: dateURL,
            configureEncoder: { $0.dateEncodingStrategy = .iso8601 },
            configureDecoder: { $0.dateDecodingStrategy = .iso8601 }
        )
        XCTAssertEqual(s2.items.first?.id, original.id)
        // Date equality to the second (iso8601 has second precision).
        let reloaded = try XCTUnwrap(s2.items.first)
        XCTAssertEqual(
            reloaded.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - External writes

    /// The MCP server writes scripts.json / ai-actions.json from another process.
    /// Without a reload the in-memory array stays authoritative and the next
    /// save() silently clobbers what it wrote.
    func testReloadPicksUpAnotherProcessesWrite() throws {
        let store = makeStore()
        store.add(stub("mine"))
        XCTAssertEqual(store.items.count, 1)

        // Stand in for the MCP server: rewrite the file behind the store's back.
        let intruder = [stub("mine"), stub("written by mcp")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(intruder).write(to: tempURL, options: .atomic)
        // Modification dates have 1s granularity on some filesystems; make the
        // write unambiguously newer than the store's last save.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: tempURL.path
        )

        XCTAssertTrue(store.reloadIfModifiedExternally())
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.last?.name, "written by mcp")
    }

    func testReloadIsANoOpWhenOnlyWeHaveWritten() {
        let store = makeStore()
        store.add(stub("mine"))
        XCTAssertFalse(
            store.reloadIfModifiedExternally(),
            "our own save must not look like an external write"
        )
    }
}
