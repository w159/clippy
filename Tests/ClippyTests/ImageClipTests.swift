import XCTest
@testable import Clippy

@MainActor
final class ImageClipTests: XCTestCase {
    private func storeImage(_ db: ClipDatabase, data: Data) throws -> Clip {
        let stored = try db.media.store(pngData: data)
        var clip = makeImageClip(stored)
        try db.saveCapturedImageClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        return clip
    }

    func testImageClipRoundTrip() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)

        let fetched = try XCTUnwrap(db.allClips().first)
        XCTAssertEqual(fetched.contentKind, .image)
        XCTAssertEqual(fetched.pixelWidth, 600)
        XCTAssertNotNil(fetched.mediaFilename)
    }

    func testImageDedupeBumpsTimestampInsteadOfDuplicating() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        _ = try storeImage(db, data: png)
        XCTAssertEqual(try db.allClips().count, 1)
    }

    func testDeleteClipRemovesMediaFiles() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        let clip = try XCTUnwrap(db.allClips().first)
        let mediaURL = db.media.url(for: try XCTUnwrap(clip.mediaFilename))
        let thumbURL = db.media.url(for: try XCTUnwrap(clip.thumbFilename))

        try db.deleteClip(id: try XCTUnwrap(clip.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbURL.path))
    }

    func testReferencedMediaFilenamesListsBothFiles() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        let clip = try XCTUnwrap(db.allClips().first)
        let referenced = try db.referencedMediaFilenames()
        XCTAssertEqual(referenced, [
            try XCTUnwrap(clip.mediaFilename),
            try XCTUnwrap(clip.thumbFilename),
        ])
    }

    func testUpdateClipImageRepointsRowAndFreesOldFile() throws {
        let db = try makeTestDatabase(self)
        let png = MediaStoreTests().makePNGData()
        _ = try storeImage(db, data: png)
        let clip = try XCTUnwrap(db.allClips().first)
        let oldMedia = try XCTUnwrap(clip.mediaFilename)
        let oldMediaURL = db.media.url(for: oldMedia)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldMediaURL.path))

        // Edit (crop) the image and save it back through the editor's DB path.
        let original = try XCTUnwrap(NSImage(data: png))
        let cropped = try XCTUnwrap(ImageEditing.cropped(original, to: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let newPNG = try XCTUnwrap(ImageEditing.pngData(cropped))
        let stored = try db.media.store(pngData: newPNG)
        try db.updateClipImage(id: try XCTUnwrap(clip.id), stored: stored)

        let updated = try XCTUnwrap(db.allClips().first)
        XCTAssertEqual(updated.mediaFilename, stored.mediaFilename)
        XCTAssertNotEqual(updated.mediaFilename, oldMedia)
        XCTAssertEqual(updated.pixelWidth, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMediaURL.path),
                       "old media file should be freed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.media.url(for: stored.mediaFilename).path))
    }

    func testCapEvictionRemovesMediaFiles() throws {
        let db = try makeTestDatabase(self)

        let png = MediaStoreTests().makePNGData()
        let stored = try db.media.store(pngData: png)
        var imageClip = makeImageClip(stored, createdAt: Date(timeIntervalSinceNow: -60))
        try db.saveCapturedImageClip(&imageClip, cap: 1)

        var newer = makeTextClip("newer")
        try db.saveCapturedClip(&newer, cap: 1)

        XCTAssertEqual(try db.allClips().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.media.url(for: stored.mediaFilename).path))
    }
}
