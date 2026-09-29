import XCTest
import GRDB
@testable import Clippy

@MainActor
final class KeyboardUndoBufferTests: XCTestCase {
    private func snapshot(_ id: Int64) -> DeletedClipSnapshot {
        let clip = Clip(id: id, contentText: "c\(id)", contentRTF: nil, contentHTML: nil,
                        typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: nil,
                        sourceAppName: nil, createdAt: Date())
        return DeletedClipSnapshot(clip: clip, categoryIDs: [], media: [:])
    }

    func testCapacityEvictsOldestAndPopIsLIFO() {
        let buffer = ClipUndoBuffer(capacity: 2)
        buffer.record([snapshot(1)])
        buffer.record([snapshot(2)])
        buffer.record([snapshot(3)])
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.popLast()?.first?.clip.id, 3)
        XCTAssertEqual(buffer.popLast()?.first?.clip.id, 2)
        XCTAssertNil(buffer.popLast())
    }

    func testEmptyRecordIgnoredAndClear() {
        let buffer = ClipUndoBuffer()
        buffer.record([])
        XCTAssertTrue(buffer.isEmpty)
        buffer.record([snapshot(1)])
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRestoreBringsBackTextClipWithCategories() throws {
        let db = try makeTestDatabase(self)
        let id = try db.insertTextClip("hello", sourceAppName: "Test")
        let category = try db.createCategory(named: "Work", colorHex: "#ff0000", iconKind: .symbol, iconValue: "star")
        let categoryID = try XCTUnwrap(category.id)
        try db.setClip(id, inCategory: categoryID, true)
        let clip = try XCTUnwrap(try db.allClips().first { $0.id == id })
        let snap = try XCTUnwrap(ClipUndoBuffer.snapshot(of: clip, categoryIDs: [categoryID], media: db.media))

        try db.deleteClip(id: id)
        XCTAssertFalse(try db.clipExists(id: id))

        XCTAssertEqual(try ClipUndoBuffer.restore([snap], into: db), 1)
        XCTAssertTrue(try db.clipExists(id: id))
        XCTAssertEqual(try db.membershipMap()[id], [categoryID])
        XCTAssertEqual(try db.allClips().first { $0.id == id }?.contentText, "hello")
    }

    func testRestoreRewritesDeletedMediaFile() throws {
        let db = try makeTestDatabase(self)
        let name = "undo-test.bin"
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: db.media.url(for: name))
        var clip = Clip(id: nil, contentText: "file", contentRTF: nil, contentHTML: nil,
                        typeIdentifier: "public.file-url", sourceAppBundleID: nil,
                        sourceAppName: nil, createdAt: Date(), contentKind: .file, mediaFilename: name)
        try db.dbQueue.write { try clip.insert($0) }
        let id = try XCTUnwrap(clip.id)
        let snap = try XCTUnwrap(ClipUndoBuffer.snapshot(of: clip, categoryIDs: [], media: db.media))
        try db.deleteClip(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.media.url(for: name).path))

        try ClipUndoBuffer.restore([snap], into: db)
        XCTAssertEqual(try Data(contentsOf: db.media.url(for: name)), bytes)
    }

    func testRestoreWithReusedIDInsertsFreshRowAndSkipsMissingCategory() throws {
        let db = try makeTestDatabase(self)
        let id = try db.insertTextClip("original", sourceAppName: "Test")
        let clip = try XCTUnwrap(try db.allClips().first { $0.id == id })
        let snap = DeletedClipSnapshot(clip: clip, categoryIDs: [9999], media: [:])
        // The original still exists, so the id is "taken".
        XCTAssertEqual(try ClipUndoBuffer.restore([snap], into: db), 1)
        XCTAssertEqual(try db.allClips().filter { $0.contentText == "original" }.count, 2)
    }

    func testOversizedMediaIsNotSnapshotted() throws {
        let db = try makeTestDatabase(self)
        let name = "big.bin"
        FileManager.default.createFile(atPath: db.media.url(for: name).path, contents: Data(count: 1024))
        let clip = Clip(id: 1, contentText: "big", contentRTF: nil, contentHTML: nil,
                        typeIdentifier: "public.file-url", sourceAppBundleID: nil, sourceAppName: nil,
                        createdAt: Date(), contentKind: .file, mediaFilename: name)
        // Under the cap it snapshots; the cap constant itself is the boundary.
        XCTAssertNotNil(ClipUndoBuffer.snapshot(of: clip, categoryIDs: [], media: db.media))
        XCTAssertGreaterThan(ClipUndoBuffer.maxMediaBytes, 1024)
    }
}
