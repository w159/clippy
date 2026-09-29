import XCTest

@testable import Clippy

/// LAY-10, OCR-06 and the sidecar directory: thumbnails are aspect-fit, keep
/// alpha, never upscale; encoded data decodes without a TIFF round trip.
final class MediaStoreThumbnailTests: CaptureTestCase {

    private func thumbnail(of stored: MediaStore.StoredImage, in db: ClipDatabase) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: db.media.url(for: stored.thumbFilename))))
    }

    func testTallImageIsFitNotCropped() throws {
        let db = try makeTestDatabase(self)
        let stored = try db.media.store(pngData: pngData(width: 278, height: 538))
        let thumb = try thumbnail(of: stored, in: db)
        XCTAssertEqual(max(thumb.pixelsWide, thumb.pixelsHigh), 400)
        XCTAssertEqual(Double(thumb.pixelsWide) / Double(thumb.pixelsHigh), 278.0 / 538.0, accuracy: 0.01)
    }

    func testSmallImageIsNotUpscaled() throws {
        let db = try makeTestDatabase(self)
        let stored = try db.media.store(pngData: pngData(width: 177, height: 100))
        let thumb = try thumbnail(of: stored, in: db)
        XCTAssertEqual(thumb.pixelsWide, 177)
        XCTAssertEqual(thumb.pixelsHigh, 100)
    }

    func testAlphaImageGetsAPNGThumbnailAndOpaqueGetsJPEG() throws {
        let db = try makeTestDatabase(self)
        let alpha = try db.media.store(pngData: pngData(width: 30, height: 30, alpha: true))
        XCTAssertTrue(alpha.thumbFilename.hasSuffix("-thumb.png"))
        XCTAssertTrue(try thumbnail(of: alpha, in: db).hasAlpha)
        let opaque = try db.media.store(pngData: pngData(width: 31, height: 31))
        XCTAssertTrue(opaque.thumbFilename.hasSuffix("-thumb.jpg"))
        // Re-storing is idempotent and reuses the existing thumbnail.
        XCTAssertEqual(try db.media.store(pngData: pngData(width: 30, height: 30, alpha: true)).thumbFilename, alpha.thumbFilename)
    }

    func testEncodedDataDecodesToPNGAndPNGPassesThrough() throws {
        let png = pngData(width: 20, height: 10)
        XCTAssertEqual(MediaStore.pngData(fromEncoded: png), png)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let tiff = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))
        let converted = try XCTUnwrap(MediaStore.pngData(fromEncoded: tiff))
        XCTAssertEqual(NSBitmapImageRep(data: converted)?.pixelsWide, 20)
        XCTAssertNil(MediaStore.pngData(fromEncoded: Data("not an image".utf8)))
    }

    func testSweepOrphansSparesTheSidecarDirectory() throws {
        let db = try makeTestDatabase(self)
        let marker = db.media.sidecarDirectory.appendingPathComponent("keep.json")
        try Data("{}".utf8).write(to: marker)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: db.media.sidecarDirectory.path)
        db.media.sweepOrphans(referencedFilenames: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFlavorStorePruneRemovesOnlyUnreferencedFiles() throws {
        let db = try makeTestDatabase(self)
        let store = FlavorStore(directory: db.media.sidecarDirectory)
        let snapshot = { (payload: String) in
            PasteboardSnapshot(items: [.init(string: nil, flavors: [.init(type: "public.url", data: Data(payload.utf8))])])
        }
        try store.write(snapshot("a"), key: "t-keep")
        try store.write(snapshot("b"), key: "t-drop")
        store.prune(keepingKeys: ["t-keep"])
        XCTAssertNotNil(store.restore(key: "t-keep"))
        XCTAssertNil(store.restore(key: "t-drop"))
        let blobs = try FileManager.default.contentsOfDirectory(atPath: db.media.sidecarDirectory.path).filter { $0.hasPrefix("flavor-") }
        XCTAssertEqual(blobs.count, 1)
    }
}
