import XCTest
@testable import Clippy

final class VisionLabelMapperTests: XCTestCase {
    func testLabelsFilterSortDedupeAndCap() {
        let labels = VisionLabelMapper.labels(from: [
            ("wine_bottle", 0.9), ("Wine bottle", 0.5), ("table", 0.1), ("glass", 0.4), ("", 0.9),
        ])
        XCTAssertEqual(labels, ["wine bottle", "glass"])
        let many = (0..<20).map { ("label\($0)", Float(0.9)) }
        XCTAssertEqual(VisionLabelMapper.labels(from: many).count, VisionLabelMapper.maxLabels)
    }

    func testSummaryCombinesLabelsAndCollapsedText() {
        let text = VisionLabelMapper.summary(labels: ["receipt"], ocrText: "Total\n  $4.20 \n")
        XCTAssertEqual(text, "Looks like: receipt.\nText in image: Total $4.20")
        XCTAssertEqual(VisionLabelMapper.summary(labels: [], ocrText: nil), "No labels or text were recognized.")
    }

    func testSummaryClipsLongText() {
        let long = String(repeating: "word ", count: 200)
        XCTAssertTrue(VisionLabelMapper.summary(labels: [], ocrText: long).hasSuffix("\u{2026}"))
    }

    func testOriginNoteLabelsFallbackHonestly() {
        let fallback = ImageDescription(origin: .classification, text: "", labels: [])
        XCTAssertEqual(fallback.originNote, "On-device classification (no generative model available)")
    }
}
