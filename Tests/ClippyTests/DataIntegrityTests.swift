import AppKit
import GRDB
import XCTest

@testable import Clippy

/// Data-loss and corruption fixes in the storage layer: unfiling must not feed
/// eviction, shared media must outlive one owner, the sidecar is not an orphan,
/// and a re-copy must not act on an older clip.
@MainActor
final class DataIntegrityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Seeded fault: no expression index, so every eviction pass sorted the whole table.
    /// Both eviction orderings must be answered from `clips_history_entry`.
    func testEvictionOrderingUsesTheHistoryEntryIndex() throws {
        let db = try makeTestDatabase(self)
        let order = ClipDatabase.historyEntrySQL
        for direction in ["ASC", "DESC"] {
            let plan = try db.dbQueue.read { connection in
                try Row.fetchAll(connection, sql: """
                    EXPLAIN QUERY PLAN SELECT id FROM clips
                    WHERE id NOT IN (SELECT clipID FROM clip_category)
                    ORDER BY \(order) \(direction), id \(direction) LIMIT 5
                    """).map { ($0["detail"] as String?) ?? "" }.joined(separator: " | ")
            }
            XCTAssertTrue(plan.contains("clips_history_entry"), "\(direction): \(plan)")
            XCTAssertFalse(plan.contains("USE TEMP B-TREE FOR ORDER BY"), "\(direction): \(plan)")
        }
    }

    private func insertTexts(_ db: ClipDatabase, prefix: String, count: Int, start: Date,
                             step: TimeInterval) throws -> [Int64] {
        try db.dbQueue.write { connection in
            var ids: [Int64] = []
            for index in 0..<count {
                var clip = makeTextClip("\(prefix)-\(index)", createdAt: start.addingTimeInterval(Double(index) * step))
                try clip.insert(connection)
                ids.append(clip.id!)
            }
            return ids
        }
    }

    private func makeCategory(_ db: ClipDatabase, _ name: String) throws -> Int64 {
        try XCTUnwrap(try db.createCategory(named: name, colorHex: "#007AFF", iconKind: .symbol, iconValue: "tag").id)
    }

    private func existingIDs(_ db: ClipDatabase) throws -> Set<Int64> {
        Set(try db.allClips().compactMap(\.id))
    }

    // MARK: Finding 1: unfiling must not feed eviction

    func testDeletingACategoryKeepsItsClipsThroughTheNextCapture() throws {
        let db = try makeTestDatabase(self)
        // 600 history clips, newer than the 200 clips a category holds.
        let history = try insertTexts(db, prefix: "h", count: 600, start: base, step: 60)
        let filed = try insertTexts(db, prefix: "f", count: 200, start: base.addingTimeInterval(-1_000_000), step: 1)
        let category = try makeCategory(db, "Keep")
        for id in filed { try db.setClip(id, inCategory: category, true) }

        try db.deleteCategory(id: category)

        var fresh = makeTextClip("fresh capture", createdAt: Date())
        try db.saveCapturedClip(&fresh, cap: 500)

        let alive = try existingIDs(db)
        XCTAssertTrue(Set(filed).isSubset(of: alive), "unfiled clips were evicted by the next capture")
        XCTAssertEqual(alive.count, 500, "the history cap still holds")
        // The cap is paid by the oldest genuine history, not by the unfiled clips.
        XCTAssertFalse(alive.contains(history[0]))
        XCTAssertTrue(alive.contains(history[599]))

        // Cmd+Z re-adds membership by id: every id must still exist (FK).
        let restored = try makeCategory(db, "Keep again")
        for id in filed { try db.setClip(id, inCategory: restored, true) }
        XCTAssertEqual(try db.clipsForCategory(restored).count, 200)
    }

    func testUnpinningAnOldClipKeepsItThroughTheNextCapture() throws {
        let db = try makeTestDatabase(self)
        _ = try insertTexts(db, prefix: "h", count: 5, start: base, step: 60)
        let ancient = try insertTexts(db, prefix: "old", count: 1, start: base.addingTimeInterval(-1_000_000), step: 1)[0]
        try db.toggleStarterMembership(clipID: ancient)  // pin
        try db.toggleStarterMembership(clipID: ancient)  // unpin: back in history

        var fresh = makeTextClip("fresh", createdAt: Date())
        try db.saveCapturedClip(&fresh, cap: 5)

        XCTAssertTrue(try existingIDs(db).contains(ancient), "an unpinned clip was evicted at once")
        XCTAssertEqual(try existingIDs(db).count, 5)
    }

    func testFileClipMovesInOneStepAndLeavesOtherCategories() throws {
        let db = try makeTestDatabase(self)
        let id = try insertTexts(db, prefix: "c", count: 1, start: base, step: 1)[0]
        let first = try makeCategory(db, "A")
        let second = try makeCategory(db, "B")
        try db.setClip(id, inCategory: first, true)

        try db.fileClip(id, into: second, leaving: [first])

        XCTAssertEqual(try db.membershipMap()[id], [second])
    }

    // MARK: Finding 2: the sidecar is not an orphan

    func testOrphanReportAndRemovalSpareTheSidecarDirectory() throws {
        let db = try makeTestDatabase(self)
        let sidecar = db.media.sidecarDirectory
        let flags = sidecar.appendingPathComponent(SensitiveFlagStore.fileName)
        try Data("{}".utf8).write(to: flags)
        let orphan = db.media.url(for: "orphan.png")
        try Data([0x1]).write(to: orphan)
        // Older than the report's 60-second in-flight guard, or nothing would be listed.
        let old = [FileAttributeKey.modificationDate: Date(timeIntervalSinceNow: -300)]
        try FileManager.default.setAttributes(old, ofItemAtPath: sidecar.path)
        try FileManager.default.setAttributes(old, ofItemAtPath: orphan.path)

        let report = try db.orphanMediaReport(remove: true)

        XCTAssertEqual(report.orphanedFiles, ["orphan.png"])
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flags.path), "sidecar data was deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: Finding 3: a re-copy acts on nothing older

    func testRecopyReportsABumpNotAnInsert() throws {
        let db = try makeTestDatabase(self)
        var first = makeTextClip("same text")
        XCTAssertTrue(try db.saveCapturedClip(&first, cap: 100))
        var again = makeTextClip("same text", createdAt: Date().addingTimeInterval(5))
        XCTAssertFalse(try db.saveCapturedClip(&again, cap: 100))
        XCTAssertEqual(again.id, first.id)
    }

    func testAppendNeverRewritesAFiledClip() throws {
        let db = try makeTestDatabase(self)
        var rich = makeTextClip("rich")
        rich.contentRTF = Data("{\\rtf1 rich}".utf8)
        try db.saveCapturedClip(&rich, cap: 100)
        let id = try XCTUnwrap(rich.id)
        let category = try makeCategory(db, "Filed")
        try db.setClip(id, inCategory: category, true)

        XCTAssertFalse(try db.appendClipText(id: id, newText: "rich\nmore"))

        let row = try XCTUnwrap(try db.allClips().first { $0.id == id })
        XCTAssertEqual(row.contentText, "rich")
        XCTAssertNotNil(row.contentRTF, "the filed clip lost its formatting")
    }

    func testAppendStillMergesAnUnfiledClip() throws {
        let db = try makeTestDatabase(self)
        var clip = makeTextClip("one")
        try db.saveCapturedClip(&clip, cap: 100)
        let id = try XCTUnwrap(clip.id)
        XCTAssertTrue(try db.appendClipText(id: id, newText: "one\ntwo"))
        XCTAssertEqual(try db.allClips().first { $0.id == id }?.contentText, "one\ntwo")
    }

    func testDeleteUnlessFiledSparesFiledClips() throws {
        let db = try makeTestDatabase(self)
        let ids = try insertTexts(db, prefix: "d", count: 2, start: base, step: 1)
        let category = try makeCategory(db, "Filed")
        try db.setClip(ids[0], inCategory: category, true)

        XCTAssertFalse(try db.deleteClipUnlessFiled(id: ids[0]))
        XCTAssertTrue(try db.deleteClipUnlessFiled(id: ids[1]))
        XCTAssertEqual(try existingIDs(db), [ids[0]])
    }

    // MARK: Finding 4: archive import keeps PNG bytes

    func testImportedPNGKeepsItsBytesSoItDedupes() throws {
        // An interlaced PNG: a NSImage/TIFF re-encode would write different bytes.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 9, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [.interlaced: true]))

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-archive-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        try png.write(to: mediaDir.appendingPathComponent("shot.png"))

        let toml = """
            schema_version = 1
            exported_at = "2026-06-11T00:00:00Z"

            [[category]]
            name = "Shots"
            color = "#FF2D55"
            icon_kind = "symbol"
            icon = "photo"
            position = 0
            starter = false

              [[category.clip]]
              kind = "image"
              media = "media/shot.png"
            """
        let dest = try makeTestDatabase(self)
        let existing = try dest.media.store(pngData: png)
        var seeded = makeImageClip(existing)
        try dest.saveCapturedImageClip(&seeded, cap: 100)

        try ClippyArchive.importTOML(toml, into: dest, baseURL: package)
        try ClippyArchive.importTOML(toml, into: dest, baseURL: package)

        let images = try dest.allClips().filter { $0.contentKind == .image }
        XCTAssertEqual(images.count, 1, "each import added the image again")
        XCTAssertEqual(images.first?.mediaFilename, existing.mediaFilename)
    }

    // MARK: Finding 5: identical file from another path

    func testRecopiedFileTakesTheNewNameAndPath() throws {
        let db = try makeTestDatabase(self)
        func fileClip(_ name: String, _ path: String) -> Clip {
            var clip = makeTextClip(name)
            clip.contentKind = .file
            clip.typeIdentifier = "public.file-url"
            clip.mediaFilename = "abc123.txt"
            clip.filePath = path
            return clip
        }
        var first = fileClip("a.txt", "/tmp/one/a.txt")
        XCTAssertTrue(try db.saveCapturedFileClip(&first, cap: 100))
        var second = fileClip("b.txt", "/tmp/two/b.txt")
        XCTAssertFalse(try db.saveCapturedFileClip(&second, cap: 100))

        let row = try XCTUnwrap(try db.allClips().first { $0.id == first.id })
        XCTAssertEqual(row.contentText, "b.txt")
        XCTAssertEqual(row.filePath, "/tmp/two/b.txt")
    }

    // MARK: Finding 6: shared media

    private func sharedMediaFixture(_ db: ClipDatabase) throws -> (file: Int64, image: Int64, names: [String]) {
        let names = ["h.png", "h-thumb.png"]
        for name in names { try Data([0x1]).write(to: db.media.url(for: name)) }
        var file = makeTextClip("h.png")
        file.contentKind = .file
        file.mediaFilename = "h.png"
        file.thumbFilename = "h-thumb.png"
        file.filePath = "/tmp/h.png"
        XCTAssertTrue(try db.saveCapturedFileClip(&file, cap: 100))
        var image = makeImageClip(.init(mediaFilename: "h.png", thumbFilename: "h-thumb.png",
                                        pixelWidth: 1, pixelHeight: 1, byteSize: 1))
        // The image copy must be its own row, not a bump of the .png file clip.
        XCTAssertTrue(try db.saveCapturedImageClip(&image, cap: 100))
        XCTAssertNotEqual(image.id, file.id)
        return (try XCTUnwrap(file.id), try XCTUnwrap(image.id), names)
    }

    private func exists(_ db: ClipDatabase, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: db.media.url(for: name).path)
    }

    func testDeletingOneOwnerKeepsMediaTheOtherStillUses() throws {
        let db = try makeTestDatabase(self)
        let fixture = try sharedMediaFixture(db)

        try db.deleteClip(id: fixture.image)
        XCTAssertTrue(fixture.names.allSatisfy { exists(db, $0) }, "shared media deleted under the file clip")

        try db.deleteClip(id: fixture.file)
        XCTAssertTrue(fixture.names.allSatisfy { !exists(db, $0) }, "last owner gone: files are freed")
    }

    func testClearHistoryKeepsMediaAFiledClipStillUses() throws {
        let db = try makeTestDatabase(self)
        let fixture = try sharedMediaFixture(db)
        let category = try makeCategory(db, "Filed")
        try db.setClip(fixture.file, inCategory: category, true)

        try db.deleteUnclassifiedClips()

        XCTAssertEqual(try existingIDs(db), [fixture.file])
        XCTAssertTrue(fixture.names.allSatisfy { exists(db, $0) })
    }

    func testEvictionKeepsMediaAFiledClipStillUses() throws {
        let db = try makeTestDatabase(self)
        let fixture = try sharedMediaFixture(db)
        let category = try makeCategory(db, "Filed")
        try db.setClip(fixture.file, inCategory: category, true)
        // A newer clip makes the (older) image clip the one eviction victim at cap 1.
        let freed: [String] = try db.dbQueue.write { connection in
            var extra = makeTextClip("newer", createdAt: Date().addingTimeInterval(10))
            try extra.insert(connection)
            return try ClipDatabase.evictOverCap(connection, cap: 1)
        }
        XCTAssertTrue(freed.isEmpty, "eviction reported shared media as free")
        XCTAssertFalse(try existingIDs(db).contains(fixture.image))
        XCTAssertTrue(fixture.names.allSatisfy { exists(db, $0) })
    }

    // MARK: Finding 7: bulk OCR clear touches only rows that have OCR state

    func testClearAllOCRTextTouchesOnlyScannedRows() throws {
        let db = try makeTestDatabase(self)
        _ = try insertTexts(db, prefix: "t", count: 3, start: base, step: 1)
        var image = makeImageClip(.init(mediaFilename: "i.png", thumbFilename: "i-thumb.png",
                                        pixelWidth: 1, pixelHeight: 1, byteSize: 1))
        try db.saveCapturedImageClip(&image, cap: 100)
        try db.setOCRText(id: try XCTUnwrap(image.id), text: "hello")

        XCTAssertEqual(try db.clearAllOCRText(), 1)
        XCTAssertEqual(try db.clearAllOCRText(), 0)
        XCTAssertNil(try db.allClips().first { $0.id == image.id }?.ocrText)
    }

    // MARK: Finding 8: failed OCR is not retried forever

    func testFailedOCRMarkerIsClearedWithTheRestAndRescanned() throws {
        let db = try makeTestDatabase(self)
        var image = makeImageClip(.init(mediaFilename: "bad.png", thumbFilename: "bad-thumb.png",
                                        pixelWidth: 1, pixelHeight: 1, byteSize: 1))
        try db.saveCapturedImageClip(&image, cap: 100)
        let id = try XCTUnwrap(image.id)
        try db.setOCRText(id: id, text: "")
        XCTAssertTrue(try db.clipsNeedingOCR(limit: 10).isEmpty)

        try db.clearAllOCRText()
        XCTAssertEqual(try db.clipsNeedingOCR(limit: 10).map(\.id), [id])
    }
}

/// Finding 3 at the monitor: automatic sensitive handling only ever removes a
/// clip that capture itself created, and honours the user's override.
final class SensitiveRecopyTests: CaptureTestCase {
    private let card = "4111 1111 1111 1111"

    private func captureFiled(_ db: ClipDatabase, _ pb: NSPasteboard, _ monitor: ClipboardMonitor) throws -> Clip {
        CapturePreferences.sensitiveAutoClearSeconds = 0  // first capture schedules nothing
        write(pb, card)
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: card))
        let category = try XCTUnwrap(try db.createCategory(
            named: "Filed", colorHex: "#007AFF", iconKind: .symbol, iconValue: "tag").id)
        try db.setClip(try XCTUnwrap(saved.id), inCategory: category, true)
        return saved
    }

    func testAutoClearNeverDeletesAFiledClip() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        var notices = 0
        monitor.autoClearNotifier = { _, _ in notices += 1 }
        let saved = try captureFiled(db, pb, monitor)

        monitor.scheduleAutoClear(changeCount: pb.changeCount, clipID: saved.id, key: saved.contentKey, after: 0.05)
        XCTAssertTrue(waitFor { notices > 0 })
        XCTAssertNil(pb.string(forType: .string), "the clipboard is still cleared")
        XCTAssertNotNil(try db.allClips().first { $0.id == saved.id }, "a filed clip was auto-deleted")
    }

    func testRecopyOfAFiledSensitiveClipLeavesItInHistory() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        var notices = 0
        monitor.autoClearNotifier = { _, _ in notices += 1 }
        let saved = try captureFiled(db, pb, monitor)

        CapturePreferences.sensitiveAutoClearSeconds = 1
        write(pb, card)
        monitor.tick()
        XCTAssertTrue(waitFor(4) { notices > 0 })
        XCTAssertNotNil(try db.allClips().first { $0.id == saved.id }, "the re-copy deleted the filed clip")
    }

    /// Seeded fault: a re-copy that only bumped an existing unfiled clip passed no id to
    /// auto-clear, so a secret captured while auto-clear was off stayed in history.
    func testRecopyOfAnUnfiledSensitiveClipIsAutoClearedFromHistory() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        var notices = 0
        monitor.autoClearNotifier = { _, _ in notices += 1 }
        CapturePreferences.sensitiveAutoClearSeconds = 0  // first capture schedules nothing
        write(pb, card)
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: card))

        CapturePreferences.sensitiveAutoClearSeconds = 1
        write(pb, card)
        monitor.tick()
        XCTAssertTrue(waitFor(4) { notices > 0 })
        XCTAssertNil(try db.allClips().first { $0.id == saved.id }, "the secret stayed in history after the re-copy")
    }

    func testNotSensitiveOverrideStopsAutoClearOfARecopy() throws {
        let db = try makeTestDatabase(self)
        let key = Clip.contentKey(kind: .text, text: card, mediaFilename: nil, filePath: nil)
        SensitiveFlagStore(directory: db.media.sidecarDirectory).setOverride(key: key, isSensitive: false)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        var notices = 0
        monitor.autoClearNotifier = { _, _ in notices += 1 }

        CapturePreferences.sensitiveAutoClearSeconds = 1
        write(pb, card)
        monitor.tick()
        _ = try XCTUnwrap(try clip(db, text: card))
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))

        XCTAssertEqual(notices, 0)
        XCTAssertEqual(pb.string(forType: .string), card, "the clipboard was cleared despite the override")
        XCTAssertNotNil(try db.allClips().first { $0.contentText == card })
    }
}
