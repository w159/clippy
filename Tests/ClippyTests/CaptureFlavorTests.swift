import PDFKit
import XCTest

@testable import Clippy

/// CAP-03: flavor-preserving capture and restore.
final class CaptureFlavorTests: CaptureTestCase {

    // MARK: CAP-03: flavors

    func testUrlAndVCardFlavorsRoundTripThroughCaptureAndPaste() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let url = Data("https://example.com/page".utf8)
        let vcard = Data("BEGIN:VCARD\nFN:Test Person\nEND:VCARD".utf8)
        let item = NSPasteboardItem()
        item.setString("Example page", forType: .string)
        item.setData(url, forType: NSPasteboard.PasteboardType("public.url"))
        item.setData(vcard, forType: NSPasteboard.PasteboardType("public.vcard"))
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([item]))
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: "Example page"))

        let store = FlavorStore(directory: db.media.sidecarDirectory)
        let restored = try XCTUnwrap(store.restore(key: saved.contentKey))
        let types = Set(restored.items[0].flavors.map(\.type))
        XCTAssertTrue(types.isSuperset(of: ["public.url", "public.vcard"]))

        // Paste it back into the same scratch pasteboard.
        pb.clearContents()
        var keystrokes = 0
        let service = PasteService(monitor: monitor, sendKeystroke: { _ in keystrokes += 1; return true },
                                   frontmostBundleID: { "com.example.target" })
        let done = expectation(description: "paste")
        var outcome: PasteResult?
        service.paste(saved, asPlainText: false) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(keystrokes, 1)
        let pasted = try XCTUnwrap(pb.pasteboardItems?.first)
        XCTAssertEqual(pasted.string(forType: .string), "Example page")
        XCTAssertEqual(pasted.data(forType: NSPasteboard.PasteboardType("public.url")), url)
        XCTAssertEqual(pasted.data(forType: NSPasteboard.PasteboardType("public.vcard")), vcard)

        // Plain-text paste drops every extra flavor.
        let plainDone = expectation(description: "plain paste")
        service.paste(saved, asPlainText: true) { _ in plainDone.fulfill() }
        wait(for: [plainDone], timeout: 5)
        let plain = try XCTUnwrap(pb.pasteboardItems?.first)
        XCTAssertEqual(plain.string(forType: .string), "Example page")
        XCTAssertNil(plain.data(forType: NSPasteboard.PasteboardType("public.url")))
    }

    func testPasteIsNotRecapturedButTheNextForeignCopyIs() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        write(pb, "original")
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: "original"))
        let before = try db.allClips().count

        let service = PasteService(monitor: monitor, sendKeystroke: { _ in true }, frontmostBundleID: { "com.example.target" })
        let done = expectation(description: "paste")
        service.paste(saved, asPlainText: true) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        monitor.tick()
        XCTAssertEqual(try db.allClips().count, before)

        write(pb, "foreign")
        monitor.tick()
        XCTAssertNotNil(try clip(db, text: "foreign"))
    }

    func testMultiItemTextPasteboardIsJoinedAndRestoredPerItem() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("alpha", forType: .string)
        second.setString("beta", forType: .string)
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([first, second]))
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: "alpha\nbeta"))

        let service = PasteService(monitor: monitor, sendKeystroke: { _ in true }, frontmostBundleID: { "com.example.target" })
        let done = expectation(description: "paste")
        service.paste(saved, asPlainText: false) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(pb.pasteboardItems?.compactMap { $0.string(forType: .string) }, ["alpha", "beta"])
    }

    func testFlavorBudgetSkipsOversizedFlavorsButKeepsSmallOnes() throws {
        let pb = makePasteboard()
        let item = NSPasteboardItem()
        item.setString("x", forType: .string)
        item.setData(Data(count: 5_000), forType: NSPasteboard.PasteboardType("com.example.big"))
        item.setData(Data(count: 10), forType: NSPasteboard.PasteboardType("com.example.small"))
        pb.clearContents()
        pb.writeObjects([item])
        let snapshot = try XCTUnwrap(PasteboardFlavors.snapshot(from: pb, budget: 100))
        XCTAssertEqual(snapshot.items[0].flavors.map(\.type), ["com.example.small"])
        XCTAssertNil(PasteboardFlavors.snapshot(from: pb, budget: 0))
    }

    func testPlainStringOnlyPasteboardStoresNoSidecar() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        write(pb, "just text")
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: "just text"))
        XCTAssertFalse(FlavorStore(directory: db.media.sidecarDirectory).hasSnapshot(key: saved.contentKey))
    }

    func testJPEGCaptureKeepsTheOriginalEncodedBytesAsAFlavor() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: pngData(width: 40, height: 30)))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        pb.clearContents()
        pb.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        monitor.tick()
        XCTAssertTrue(try waitFor { try db.allClips().contains { $0.contentKind == .image } })
        let saved = try XCTUnwrap(try db.allClips().first { $0.contentKind == .image })
        XCTAssertEqual(saved.pixelWidth, 40)

        let flavors = try XCTUnwrap(FlavorStore(directory: db.media.sidecarDirectory).restore(key: saved.contentKey))
        XCTAssertEqual(flavors.items[0].flavors.first { $0.type == "public.jpeg" }?.data, jpeg)

        // Paste restores PNG plus the original JPEG.
        pb.clearContents()
        let service = PasteService(monitor: monitor, sendKeystroke: { _ in true }, frontmostBundleID: { "com.example.target" })
        let done = expectation(description: "paste")
        service.paste(saved, asPlainText: false) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(pb.data(forType: .png))
        XCTAssertEqual(pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")), jpeg)
    }

    func testPDFOnlyPasteboardBecomesAnImageClipWithThePDFPreserved() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 120, height: 80)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: pdf)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        pb.clearContents()
        pb.setData(pdf as Data, forType: .pdf)
        monitor.tick()
        XCTAssertTrue(try waitFor { try db.allClips().contains { $0.contentKind == .image } })
        let saved = try XCTUnwrap(try db.allClips().first { $0.contentKind == .image })
        let flavors = try XCTUnwrap(FlavorStore(directory: db.media.sidecarDirectory).restore(key: saved.contentKey))
        XCTAssertNotNil(flavors.items[0].flavors.first { $0.type == "com.adobe.pdf" })
    }

    func testColorOnlyPasteboardBecomesAHexClip() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        pb.declareTypes([.color], owner: nil)
        NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1).write(to: pb)
        monitor.tick()
        let saved = try XCTUnwrap(try clip(db, text: "#FF8000"))
        XCTAssertEqual(saved.typeIdentifier, NSPasteboard.PasteboardType.color.rawValue)
    }

    func testVCardOnlyPasteboardBecomesATextClip() throws {
        let db = try makeTestDatabase(self)
        let pb = makePasteboard()
        let monitor = makeMonitor(db, pb)
        let card = "BEGIN:VCARD\nFN:Test Person\nEND:VCARD"
        pb.clearContents()
        pb.setData(Data(card.utf8), forType: NSPasteboard.PasteboardType("public.vcard"))
        monitor.tick()
        XCTAssertNotNil(try clip(db, text: card))
    }
}
