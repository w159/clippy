import PDFKit
import XCTest
@testable import Clippy

final class OCRPDFTests: XCTestCase {
    /// Builds a PDF whose pages carry the given text (nil = blank "scanned" page).
    private func makePDF(pages: [String?]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let attributed = NSAttributedString(
                    string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 20, y: 100)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func testTextLayerIsUsedWithoutVision() throws {
        let doc = try makePDF(pages: ["First page", "Second page"])
        var scannedCalls = 0
        let result = OCRService.recognizePDF(document: doc, maxPages: 10) { _ in scannedCalls += 1; return nil }
        guard case .success(let text) = result else { return XCTFail("expected success") }
        XCTAssertTrue(text.contains("First page"))
        XCTAssertTrue(text.contains("Second page"))
        XCTAssertEqual(scannedCalls, 0)
    }

    func testPageLimitIsHonoured() throws {
        let doc = try makePDF(pages: ["alpha", "bravo", "charlie"])
        guard case .success(let text) = OCRService.recognizePDF(document: doc, maxPages: 2, scannedPage: { _ in nil })
        else { return XCTFail("expected success") }
        XCTAssertTrue(text.contains("alpha") && text.contains("bravo"))
        XCTAssertFalse(text.contains("charlie"))
    }

    func testScannedPageFallsBackToRecognizer() throws {
        let doc = try makePDF(pages: ["typed", nil])
        var scannedCalls = 0
        guard case .success(let text) = OCRService.recognizePDF(document: doc, maxPages: 5, scannedPage: { _ in
            scannedCalls += 1
            return " from vision "
        }) else { return XCTFail("expected success") }
        XCTAssertEqual(scannedCalls, 1, "only the blank page needs Vision")
        XCTAssertTrue(text.hasSuffix("from vision"))
    }

    func testUnreadablePDFFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let done = expectation(description: "done")
        OCRService.recognizeText(in: url) { result in
            if case .failure = result {} else { XCTFail("expected failure") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
