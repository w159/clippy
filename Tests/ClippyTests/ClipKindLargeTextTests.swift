import XCTest

@testable import Clippy

/// CAP-07: kind detection and previews take a prefix before trimming, so huge
/// text is neither copied nor scanned in full, and behavior on ordinary text
/// is unchanged.
final class ClipKindLargeTextTests: XCTestCase {

    func testVeryLargeStringIsPlainTextAndFast() {
        let huge = String(repeating: "lorem ipsum ", count: 500_000)  // ~6 MB
        let start = Date()
        XCTAssertEqual(ClipKind.detect(huge), .text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testHugeWhitespaceThenLinkStillClassifies() {
        let padded = String(repeating: " \n", count: 50_000) + "https://example.com/a" + String(repeating: " ", count: 3_000)
        XCTAssertEqual(ClipKind.detect(padded), .link)
    }

    func testOrdinaryDetectionUnchanged() {
        XCTAssertEqual(ClipKind.detect("  https://example.com  "), .link)
        XCTAssertEqual(ClipKind.detect("me@example.com"), .email)
        XCTAssertEqual(ClipKind.detect("/usr/local/bin"), .filePath)
        XCTAssertEqual(ClipKind.detect("two words"), .text)
        XCTAssertEqual(ClipKind.detect("   \n "), .text)
        if case .colorValue = ClipKind.detect("\n#FF8800\n") {} else { XCTFail("padded color should still be a color") }
    }

    func testTextJustOverTheLimitIsText() {
        let url = "https://example.com/" + String(repeating: "a", count: 2100)
        XCTAssertEqual(ClipKind.detect(url), .text)
        let shortEnough = "https://example.com/" + String(repeating: "a", count: 2000)
        XCTAssertEqual(ClipKind.detect(shortEnough), .link)
    }

    func testPreviewTextTrimsAndCaps() {
        XCTAssertEqual(makeTextClip("  \n hello world \n").previewText, "hello world")
        let big = makeTextClip(String(repeating: "\n", count: 10_000) + String(repeating: "x", count: 5_000_000))
        XCTAssertEqual(big.previewText.count, 300)
        XCTAssertEqual(makeTextClip("   ").previewText, "")
    }

    func testContentKeyIsStableAndKindScoped() {
        XCTAssertEqual(makeTextClip("abc").contentKey, makeTextClip("abc").contentKey)
        XCTAssertNotEqual(makeTextClip("abc").contentKey, makeTextClip("abd").contentKey)
        XCTAssertTrue(makeTextClip("abc").contentKey.hasPrefix("t-"))
        XCTAssertFalse(makeTextClip("abc").contentKey.contains("abc"), "the key never embeds content")
    }
}
