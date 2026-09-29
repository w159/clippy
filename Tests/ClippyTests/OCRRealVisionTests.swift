import AppKit
import XCTest
@testable import Clippy

/// OCR-12: verifies `automaticallyDetectsLanguage` against REAL Vision with a
/// synthetic multi-script image. Opt-in only: set `CLIPPY_REAL_VISION=1`.
/// CI never runs it (cold Vision can take ~24s or lack models).
final class OCRRealVisionTests: XCTestCase {
    private func render(lines: [String]) throws -> URL {
        let size = NSSize(width: 900, height: 120 * CGFloat(lines.count) + 40)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, line) in lines.enumerated() {
            NSString(string: line).draw(
                at: NSPoint(x: 20, y: size.height - 110 - CGFloat(index) * 120),
                withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-real-\(UUID().uuidString).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func recognize(_ url: URL, timeout: TimeInterval) -> OCRService.RecognitionResult? {
        let done = expectation(description: "vision")
        var result: OCRService.RecognitionResult?
        OCRService.recognizeText(in: url) { result = $0; done.fulfill() }
        _ = XCTWaiter().wait(for: [done], timeout: timeout)
        return result
    }

    func testAutomaticLanguageDetectionReadsLatinAndCyrillic() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CLIPPY_REAL_VISION"] != "1",
            "Opt-in: set CLIPPY_REAL_VISION=1 to run real Vision")
        let savedLanguages = OCRPreferences.languages
        OCRPreferences.languages = []  // automatic detection
        OCRPreferences.useDocumentRecognition = false
        defer { OCRPreferences.languages = savedLanguages }

        let probeURL = try render(lines: ["Hello"])
        defer { try? FileManager.default.removeItem(at: probeURL) }
        let probe = recognize(probeURL, timeout: 20)
        guard case .success(let probeText)? = probe, !probeText.isEmpty else {
            throw XCTSkip("Vision probe failed or exceeded 20s")
        }

        let url = try render(lines: ["Invoice total", "Привет мир"])
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let text)? = recognize(url, timeout: 60) else {
            return XCTFail("recognition failed or timed out")
        }
        XCTAssertTrue(text.lowercased().contains("invoice"), "Latin line missing: \(text)")
        XCTAssertTrue(text.contains("Привет") || text.contains("привет"), "Cyrillic line missing: \(text)")
    }
}
