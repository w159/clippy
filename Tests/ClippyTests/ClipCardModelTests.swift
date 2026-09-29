import XCTest
@testable import Clippy

final class ClipCardModelTests: XCTestCase {
    private func clip(_ text: String, title: String? = nil, ocr: String? = nil, image: Bool = false) -> Clip {
        var value = Clip(id: 7, contentText: text, typeIdentifier: "public.utf8-plain-text",
                         sourceAppBundleID: nil, sourceAppName: "Edge", createdAt: Date())
        value.userTitle = title
        if image { value.contentKind = .image; value.thumbFilename = "t.png" }
        value.ocrText = ocr
        return value
    }

    func testMaskedAccessibilityNeverContainsContentOrTitle() {
        let secret = "apikey_253c23af810d99deadbeef"
        let model = ClipCardModel.make(clip: clip(secret, title: secret), isSelected: true, isPinned: true,
                                       isSensitive: true, isOCRRunning: false, query: "apikey")
        XCTAssertFalse(model.accessibilityLabel.contains("apikey"))
        XCTAssertFalse(model.accessibilityValue.contains("apikey"))
        XCTAssertTrue(model.accessibilityLabel.hasPrefix("Sensitive"))
        XCTAssertTrue(model.accessibilityValue.contains("selected"))
        XCTAssertTrue(model.accessibilityValue.contains("pinned"))
    }

    func testValueReportsOCRStates() {
        let image = clip("", ocr: "hello world", image: true)
        let running = ClipCardModel.make(clip: image, isSelected: false, isPinned: false,
                                         isSensitive: false, isOCRRunning: true, query: "")
        XCTAssertTrue(running.accessibilityValue.contains("extracting text"))
        let done = ClipCardModel.make(clip: image, isSelected: false, isPinned: false,
                                      isSensitive: false, isOCRRunning: false, query: "hello")
        XCTAssertTrue(done.matchedInOCR)
        XCTAssertTrue(done.accessibilityValue.contains("matched in image text"))
    }

    func testOCRMatchIgnoredForTextClipsAndTitleMatches() {
        XCTAssertFalse(ClipCardModel.ocrMatched(clip: clip("hello", ocr: "hello"), query: "hello"))
        XCTAssertFalse(ClipCardModel.ocrMatched(clip: clip("", title: "hello", ocr: "hello", image: true), query: "hello"))
    }

    func testQuickPasteDigitBounds() {
        let base = clip("x")
        func digit(_ value: Int) -> Int? {
            ClipCardModel.make(clip: base, isSelected: false, isPinned: false, isSensitive: false,
                               isOCRRunning: false, query: "", quickPasteDigit: value).quickPasteDigit
        }
        XCTAssertNil(digit(0))
        XCTAssertEqual(digit(9), 9)
        XCTAssertNil(digit(10))
    }

    func testHighlightRanges() {
        XCTAssertEqual(HighlightedPreview.matchCount("Foo bar foo", query: "foo"), 2)
        XCTAssertEqual(HighlightedPreview.matchCount("Foo", query: ""), 0)
        XCTAssertEqual(String(HighlightedPreview.attributed("Foo bar", query: "bar", color: .red).characters), "Foo bar")
    }

    func testHeaderPlanDropsAppNameFirstAndKeepsTimestamp() {
        let widths = CardHeaderPlan.Widths(timestamp: 34, kindGlyph: 16, pin: 12, titleMinimum: 48,
                                           appName: 70, categories: 30, richBadge: 14, appIcon: 16, spacing: 6)
        let full = CardHeaderPlan.required(.full, widths)
        XCTAssertEqual(CardHeaderPlan.variant(available: full, widths: widths), .full)
        XCTAssertEqual(CardHeaderPlan.variant(available: full - 1, widths: widths), .noAppName)
        let noName = CardHeaderPlan.required(.noAppName, widths)
        XCTAssertLessThan(noName, full)
        XCTAssertEqual(CardHeaderPlan.variant(available: noName - 1, widths: widths), .essentialsWithIcon)
        XCTAssertEqual(CardHeaderPlan.variant(available: 10, widths: widths), .minimal)
        for variant in CardHeaderPlan.Variant.allCases {
            XCTAssertFalse(variant.kept.contains { $0 == .appName } && variant != .full)
        }
    }
}
