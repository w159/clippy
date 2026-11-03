import AppKit
import GRDB
import XCTest
@testable import Clippy

/// List fetches (search hits, the panel window) skip the RTF and HTML blobs; the
/// blobs come back through `ClipDatabase.withRichContent` right before paste,
/// copy, edit and undo, and no write path may null them.
final class LazyRichContentTests: CaptureTestCase {
    private let rtf = Data("{\\rtf1\\ansi invoice styled}".utf8)
    private let html = Data("<b>invoice</b> styled".utf8)

    @discardableResult
    private func saveRich(_ db: ClipDatabase, text: String = "invoice rich") throws -> Int64 {
        var clip = makeTextClip(text)
        clip.contentRTF = rtf
        clip.contentHTML = html
        try db.saveCapturedClip(&clip, cap: 1_000)
        return try XCTUnwrap(clip.id)
    }

    private func searchHit(_ db: ClipDatabase, id: Int64) throws -> Clip {
        try XCTUnwrap(try db.search(matching: "invoice", limit: 10).clips.first { $0.id == id })
    }

    private func loadWindow(_ loader: ClipWindowLoader, _ db: ClipDatabase) throws -> ClipWindow {
        try db.dbQueue.read { try loader.load($0, limit: 300, generation: db.contentGeneration) }
    }

    func testSearchHitIsLightAndResolvesToTheSavedBlobs() throws {
        let db = try makeTestDatabase(self)
        let id = try saveRich(db)
        let hit = try searchHit(db, id: id)
        XCTAssertNil(hit.contentRTF)
        XCTAssertNil(hit.contentHTML)
        XCTAssertTrue(hit.richContentOmitted)
        XCTAssertTrue(hit.hasRichContent, "badges and editor mode must not depend on the light copy")

        let full = try db.withRichContent(hit)
        XCTAssertEqual(full.contentRTF, rtf)
        XCTAssertEqual(full.contentHTML, html)
        XCTAssertFalse(full.richContentOmitted)
        XCTAssertEqual(full.contentText, hit.contentText)
    }

    func testPlainClipIsNeverMarkedOmitted() throws {
        let db = try makeTestDatabase(self)
        var plain = makeTextClip("invoice plain")
        try db.saveCapturedClip(&plain, cap: 1_000)
        let hit = try XCTUnwrap(try db.search(matching: "invoice", limit: 10).clips.first)
        XCTAssertFalse(hit.richContentOmitted)
        XCTAssertFalse(hit.hasRichContent)
        XCTAssertEqual(try db.withRichContent(hit), hit)
    }

    func testWindowClipsAreLightOnlyWhenRich() throws {
        let db = try makeTestDatabase(self)
        let richID = try saveRich(db, text: "window rich")
        var plain = makeTextClip("window plain")
        try db.saveCapturedClip(&plain, cap: 1_000)
        let window = try loadWindow(ClipWindowLoader(), db)

        let rich = try XCTUnwrap(window.clips.first { $0.id == richID })
        XCTAssertNil(rich.contentRTF)
        XCTAssertNil(rich.contentHTML)
        XCTAssertTrue(rich.richContentOmitted)
        let plainClip = try XCTUnwrap(window.clips.first { $0.id == plain.id })
        XCTAssertFalse(plainClip.richContentOmitted)
        XCTAssertFalse(plainClip.hasRichContent)
    }

    func testUnchangedWindowPulseDecodesNothing() throws {
        let db = try makeTestDatabase(self)
        try saveRich(db)
        let loader = ClipWindowLoader()
        _ = try loadWindow(loader, db)
        XCTAssertEqual(loader.lastDecodedRowCount, 1)
        let again = try loadWindow(loader, db)
        XCTAssertEqual(loader.lastDecodedRowCount, 0, "the light flag must not make rows look stale")
        XCTAssertTrue(try XCTUnwrap(again.clips.first).richContentOmitted)
    }

    func testEditsOfALightClipKeepBothBlobs() throws {
        let db = try makeTestDatabase(self)
        let id = try saveRich(db)
        let light = try searchHit(db, id: id)
        XCTAssertTrue(light.richContentOmitted)

        let pinned = try XCTUnwrap(try db.starterCategoryID())
        try db.setClip(id, inCategory: pinned, true)
        try db.updateClipTitle(id: id, userTitle: "Renamed")
        let category = try db.createCategory(named: "Billing", colorHex: "#154734", iconKind: .symbol, iconValue: "folder")
        try db.setClip(id, inCategory: try XCTUnwrap(category.id), true)
        try db.setOCRText(id: id, text: "scanned words")

        let stored = try XCTUnwrap(try db.dbQueue.read { try Clip.fetchOne($0, key: id) })
        XCTAssertEqual(stored.contentRTF, rtf)
        XCTAssertEqual(stored.contentHTML, html)
        XCTAssertEqual(stored.userTitle, "Renamed")
        XCTAssertEqual(stored.ocrText, "scanned words")
        XCTAssertFalse(stored.richContentOmitted, "the full fetch is never light")
    }

    func testCaptureOfTheSameContentKeepsBlobs() throws {
        let db = try makeTestDatabase(self)
        let id = try saveRich(db)
        var again = makeTextClip("invoice rich")
        again.contentRTF = rtf
        again.contentHTML = html
        try db.saveCapturedClip(&again, cap: 1_000)
        let stored = try XCTUnwrap(try db.dbQueue.read { try Clip.fetchOne($0, key: id) })
        XCTAssertEqual(stored.contentRTF, rtf)
        XCTAssertEqual(stored.contentHTML, html)
    }

    func testUndoDeleteOfALightClipRestoresBlobs() throws {
        let db = try makeTestDatabase(self)
        let id = try saveRich(db)
        let light = try searchHit(db, id: id)
        let snapshot = try XCTUnwrap(
            ClipUndoBuffer.snapshot(of: light, categoryIDs: [], media: db.media, database: db))
        XCTAssertEqual(snapshot.clip.contentRTF, rtf)
        try db.deleteClip(id: id)
        XCTAssertEqual(try ClipUndoBuffer.restore([snapshot], into: db), 1)
        let restored = try XCTUnwrap(try db.allClips().first)
        XCTAssertEqual(restored.contentRTF, rtf)
        XCTAssertEqual(restored.contentHTML, html)
    }

    func testCopyOfALightClipWritesRichFlavors() throws {
        let db = try makeTestDatabase(self)
        let id = try saveRich(db)
        let light = try searchHit(db, id: id)
        let pb = makePasteboard()
        XCTAssertTrue(ClipCopyBridge.copy([light], media: db.media, database: db, pasteboard: pb))
        XCTAssertEqual(pb.string(forType: .string), "invoice rich")
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
        XCTAssertEqual(pb.data(forType: .html), html)
    }

    func testPasteServiceCopyOfALightClipWritesRichFlavors() throws {
        let db = try makeTestDatabase(self)
        let id = try saveRich(db)
        let light = try searchHit(db, id: id)
        let pb = makePasteboard()
        let service = PasteService(monitor: makeMonitor(db, pb), sendKeystroke: { _ in true },
                                   frontmostBundleID: { "com.example.target" })
        if case .failure(let error) = service.copy(light, asPlainText: false) { XCTFail("copy failed: \(error)") }
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
        XCTAssertEqual(pb.data(forType: .html), html)
    }

    func testLightFlagIsNeverEncoded() throws {
        let db = try makeTestDatabase(self)
        let light = try searchHit(db, id: try saveRich(db))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(light)) as? [String: Any]
        let keys = try XCTUnwrap(json).keys
        XCTAssertFalse(keys.contains("richContentOmitted"))
        XCTAssertFalse(keys.contains("hasRichContent"))
    }

    func testLightDecodeMatchesFullDecodeFieldByField() throws {
        let db = try makeTestDatabase(self)
        var full = makeTextClip("light full", createdAt: Date(timeIntervalSince1970: 1_700_000_123.456))
        full.contentRTF = rtf
        full.contentHTML = html
        full.contentKind = .image
        full.mediaFilename = "m.png"
        full.thumbFilename = "t.png"
        full.pixelWidth = 640
        full.pixelHeight = 480
        full.byteSize = 12_345
        full.userTitle = "Title"
        full.filePath = "/tmp/f.png"
        full.ocrText = "scanned"
        var bare = makeTextClip("light bare")
        bare.sourceAppBundleID = nil
        bare.sourceAppName = nil
        try db.dbQueue.write { try full.insert($0); try bare.insert($0) }
        let ids = [try XCTUnwrap(full.id), try XCTUnwrap(bare.id)]

        let (light, fulls) = try db.dbQueue.read { conn in
            (try Clip.fetchLight(conn, ids: ids).sorted { $0.id! < $1.id! },
             try Clip.fetchAll(conn, keys: ids).sorted { $0.id! < $1.id! })
        }
        XCTAssertEqual(light.count, 2)
        for (l, f) in zip(light, fulls) {
            var expected = f
            expected.contentRTF = nil
            expected.contentHTML = nil
            expected.richContentOmitted = f.contentRTF != nil || f.contentHTML != nil
            XCTAssertEqual(l, expected)
            XCTAssertEqual(l.richContentOmitted, expected.richContentOmitted)
        }
        XCTAssertTrue(light[0].richContentOmitted)
        XCTAssertFalse(light[1].richContentOmitted)
    }
}
