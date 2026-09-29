import AppKit
import XCTest
@testable import Clippy

/// DAT-07/09: package export/import with bundled media, relative paths,
/// file clips, traversal rejection, category order and metadata merge.
final class DataLayerArchiveTests: XCTestCase {

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return MediaStore.pngData(from: image)!
    }

    /// A category holding one text, one image and one file clip (with bytes).
    private func makeSource() throws -> (db: ClipDatabase, fileName: String) {
        let db = try makeTestDatabase(self)
        let category = try db.createCategory(named: "Mixed", colorHex: "#00FF00", iconKind: .symbol, iconValue: "tag")
        let categoryID = try XCTUnwrap(category.id)

        var text = makeTextClip("plain text")
        try db.saveCapturedClip(&text, cap: 100)

        let stored = try db.media.store(pngData: pngData())
        var image = makeImageClip(stored)
        try db.saveCapturedImageClip(&image, cap: 100)

        let source = try tempDir("srcfile").appendingPathComponent("report.txt")
        try Data("file body".utf8).write(to: source)
        let file = try db.media.storeFile(at: source)
        var fileClip = Clip(
            id: nil, contentText: "report.txt", contentRTF: nil, contentHTML: nil,
            typeIdentifier: "public.file-url", sourceAppBundleID: nil, sourceAppName: "Finder",
            createdAt: Date(), contentKind: .file, mediaFilename: file.mediaFilename,
            thumbFilename: nil, pixelWidth: nil, pixelHeight: nil, byteSize: file.byteSize)
        fileClip.filePath = source.path
        try db.saveCapturedFileClip(&fileClip, cap: 100)

        for clip in try db.allClips() { try db.setClip(try XCTUnwrap(clip.id), inCategory: categoryID, true) }
        return (db, file.mediaFilename)
    }

    func testPackageRoundTripCarriesImagesAndFileClipsToAnotherDatabase() throws {
        let (source, fileMedia) = try makeSource()
        let out = try tempDir("pkg").appendingPathComponent("Export.clippyarchive")

        let result = try ClippyArchive.exportPackage(from: source, to: out)
        XCTAssertEqual(result.mediaFiles, 2)
        XCTAssertTrue(result.missingMedia.isEmpty)
        let toml = try String(contentsOf: out.appendingPathComponent("clippy.toml"))
        XCTAssertFalse(toml.contains(source.media.directory.path), "no absolute local paths in the archive")
        XCTAssertTrue(toml.contains("media/\(fileMedia)"))

        let dest = try makeTestDatabase(self)
        let summary = try ClippyArchive.importPackage(at: out, into: dest)
        XCTAssertEqual(summary.clips, 3)
        XCTAssertEqual(summary.skippedImages + summary.skippedFiles, 0)

        let clips = try dest.allClips()
        let image = try XCTUnwrap(clips.first { $0.contentKind == .image })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.media.url(for: try XCTUnwrap(image.mediaFilename)).path))
        let file = try XCTUnwrap(clips.first { $0.contentKind == .file })
        XCTAssertEqual(file.contentText, "report.txt")
        XCTAssertEqual(file.filePath, try XCTUnwrap(source.allClips().first { $0.contentKind == .file }?.filePath))
        XCTAssertEqual(file.mediaFilename, fileMedia, "same content hash on both Macs")
        XCTAssertEqual(try Data(contentsOf: dest.media.url(for: fileMedia)), Data("file body".utf8))

        // Idempotent: importing again duplicates nothing.
        try ClippyArchive.importPackage(at: out, into: dest)
        XCTAssertEqual(try dest.allClips().count, 3)
    }

    func testImportRejectsTraversalAndAbsoluteMediaPaths() throws {
        let base = try tempDir("base")
        let secret = try tempDir("outside").appendingPathComponent("secret.png")
        try pngData().write(to: secret)
        XCTAssertNil(ClippyArchive.resolveMedia("../\(secret.deletingLastPathComponent().lastPathComponent)/secret.png", in: base))
        XCTAssertNil(ClippyArchive.resolveMedia("media/../../x.png", in: base))
        XCTAssertNil(ClippyArchive.resolveMedia(secret.path, in: base))
        XCTAssertNil(ClippyArchive.resolveMedia("", in: base))
        XCTAssertNotNil(ClippyArchive.resolveMedia("media/ok.png", in: base))

        // End to end: a hostile manifest pointing outside the package imports nothing.
        let pkg = base.appendingPathComponent("evil.clippyarchive")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let toml = """
            schema_version = 1
            exported_at = "2026-01-01T00:00:00Z"

            [[category]]
            name = "Evil"
            color = "#000000"
            icon_kind = "symbol"
            icon = "tag"
            position = 0
            starter = false

              [[category.clip]]
              kind = "image"
              media = "../\(secret.deletingLastPathComponent().lastPathComponent)/secret.png"
            """
        try toml.write(to: pkg.appendingPathComponent("clippy.toml"), atomically: true, encoding: .utf8)
        let db = try makeTestDatabase(self)
        let summary = try ClippyArchive.importPackage(at: pkg, into: db)
        XCTAssertEqual(summary.skippedImages, 1)
        XCTAssertTrue(try db.allClips().isEmpty)
    }

    func testImportPackageWithoutManifestThrows() throws {
        let empty = try tempDir("empty")
        let db = try makeTestDatabase(self)
        XCTAssertThrowsError(try ClippyArchive.importPackage(at: empty, into: db)) {
            XCTAssertEqual($0 as? ClippyArchiveError, .missingManifest(empty.path))
        }
    }

    func testExportOrdersClipsByCategorySortOrderNotCreationDate() throws {
        let db = try makeTestDatabase(self)
        let category = try db.createCategory(named: "Ordered", colorHex: "#1", iconKind: .symbol, iconValue: "t")
        let categoryID = try XCTUnwrap(category.id)
        for (index, text) in ["one", "two", "three"].enumerated() {
            var clip = makeTextClip(text, createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)))
            try db.saveCapturedClip(&clip, cap: 100)
        }
        let byText = Dictionary(uniqueKeysWithValues: try db.allClips().map { ($0.contentText, $0.id!) })
        for text in ["one", "two", "three"] { try db.setClip(byText[text]!, inCategory: categoryID, true) }
        // Custom order: three, one, two (the opposite of createdAt order).
        try db.moveClip(byText["three"]!, inCategory: categoryID, before: nil)
        try db.moveClip(byText["two"]!, inCategory: categoryID, before: nil)
        try db.moveClip(byText["one"]!, inCategory: categoryID, before: byText["two"]!)
        let group = try XCTUnwrap(db.clipsGroupedByCategory().first { $0.category.id == categoryID })
        XCTAssertEqual(group.clips.map(\.contentText), ["three", "one", "two"])
    }

    func testDuplicateImportMergesNewestMetadata() throws {
        let db = try makeTestDatabase(self)
        var existing = makeTextClip("shared", createdAt: Date(timeIntervalSince1970: 1_000))
        try db.saveCapturedClip(&existing, cap: 100)
        let toml = """
            schema_version = 1
            exported_at = "2026-01-01T00:00:00Z"

            [[category]]
            name = "C"
            color = "#000000"
            icon_kind = "symbol"
            icon = "tag"
            position = 0
            starter = false

              [[category.clip]]
              kind = "text"
              text = "shared"
              title = "Newer title"
              source_app = "Other Mac App"
              created_at = "2026-01-01T00:00:00Z"
            """
        try ClippyArchive.importTOML(toml, into: db)
        let merged = try XCTUnwrap(db.allClips().first { $0.contentText == "shared" })
        XCTAssertEqual(try db.allClips().count, 1)
        XCTAssertEqual(merged.userTitle, "Newer title")
        XCTAssertEqual(merged.sourceAppName, "Other Mac App")

        // An OLDER incoming copy must not clobber newer local metadata.
        let older = toml.replacingOccurrences(of: "created_at = \"2026-01-01T00:00:00Z\"", with: "created_at = \"1999-01-01T00:00:00Z\"")
            .replacingOccurrences(of: "Newer title", with: "Stale title")
        try ClippyArchive.importTOML(older, into: db)
        XCTAssertEqual(try db.allClips().first?.userTitle, "Newer title")
    }

    func testPathReferenceFileClipsImportInsteadOfBeingSkipped() throws {
        let db = try makeTestDatabase(self)
        let toml = """
            schema_version = 1
            exported_at = "2026-01-01T00:00:00Z"

            [[category]]
            name = "C"
            color = "#000000"
            icon_kind = "symbol"
            icon = "tag"
            position = 0
            starter = false

              [[category.clip]]
              kind = "file"
              file_name = "notes.md"
              file_path = "/Users/someone/notes.md"

              [[category.clip]]
              kind = "file"
            """
        let summary = try ClippyArchive.importTOML(toml, into: db)
        XCTAssertEqual(summary.clips, 1)
        XCTAssertEqual(summary.skippedFiles, 1, "no bytes and no path: nothing to import")
        XCTAssertEqual(try db.allClips().first?.filePath, "/Users/someone/notes.md")
    }
}
