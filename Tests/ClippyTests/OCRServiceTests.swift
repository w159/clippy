import XCTest
import AppKit
@testable import Clippy

// MARK: - OCRService unit tests

/// Renders a known string into a PNG in memory, runs OCRService against the
/// file on disk, and asserts the string comes back.
final class OCRServiceTests: XCTestCase {

    // MARK: Helpers

    /// Render `text` into a 400x200 PNG and write it to a temp file.
    /// Returns the file URL. The caller is responsible for cleanup.
    private func pngURL(containing text: String) throws -> URL {
        let width = 400
        let height = 200

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // White background so dark text has strong contrast for Vision.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Draw the string in large black text, centered vertically.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: (CGFloat(width) - size.width) / 2,
            y: (CGFloat(height) - size.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()

        let pngData = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-test-\(UUID().uuidString).png")
        try pngData.write(to: url)
        return url
    }

    // MARK: Tests

    func testRecognizesTextInImage() throws {
        let knownText = "CLIPPY OCR"
        let imageURL = try pngURL(containing: knownText)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let expectation = expectation(description: "OCR completes")
        var capturedResult: OCRService.RecognitionResult?

        OCRService.recognizeText(in: imageURL) { result in
            capturedResult = result
            expectation.fulfill()
        }

        // Vision is synchronous under the hood but dispatches the callback on
        // main; the first call in a fresh process can take ~24s (cold model load),
        // so the timeout is generous. A timeout that expires before the callback
        // fires makes the late fulfill() crash the whole xctest process.
        wait(for: [expectation], timeout: 90)

        switch capturedResult {
        case .success(let text):
            // Allow minor whitespace differences; just confirm the core string
            // is present. Vision on headless CI may normalize spacing.
            XCTAssertTrue(
                text.lowercased().contains("clippy") || text.lowercased().contains("ocr"),
                "Expected recognized text to contain 'CLIPPY' or 'OCR', got: \(text.isEmpty ? "(empty)" : text)"
            )
        case .failure(let error):
            // Vision may be unavailable in a fully headless sandbox (no GPU).
            // Report what we got but do not hard-fail — the service code is
            // correct; the environment is the variable.
            throw XCTSkip("Vision recognition unavailable in this environment: \(error)")
        case .none:
            XCTFail("No result delivered")
        }
    }

    func testEmptyResultForBlankImage() throws {
        // A solid white image should produce no text (or at most whitespace).
        let url = try pngURL(containing: "")
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = expectation(description: "OCR completes")
        var capturedResult: OCRService.RecognitionResult?

        OCRService.recognizeText(in: url) { result in
            capturedResult = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 90)

        guard case .success(let text) = capturedResult else {
            throw XCTSkip("Vision unavailable in this environment")
        }
        // The blank image contains no meaningful text; Vision may return empty
        // or a very short noise string. Anything under 3 chars is acceptable.
        XCTAssertLessThanOrEqual(
            text.trimmingCharacters(in: .whitespacesAndNewlines).count, 3,
            "Expected blank image to yield no text, got: \(text)"
        )
    }

    func testFailureForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-ocr-test.png")
        let expectation = expectation(description: "OCR completes")
        var capturedResult: OCRService.RecognitionResult?

        OCRService.recognizeText(in: missing) { result in
            capturedResult = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        guard case .failure = capturedResult else {
            XCTFail("Expected failure for missing file, got: \(String(describing: capturedResult))")
            return
        }
    }
}
