import XCTest
@testable import Clippy

final class IntentQueryMapperTests: XCTestCase {
    private func clip(_ text: String, id: Int64? = 1, title: String? = nil, kind: ClipContentKind = .text) -> Clip {
        var value = Clip(id: id, contentText: text, contentRTF: nil, contentHTML: nil, typeIdentifier: "public.utf8-plain-text",
                         sourceAppBundleID: nil, sourceAppName: nil, createdAt: Date())
        value.userTitle = title
        value.contentKind = kind
        return value
    }

    func testGrammarPassThroughAndNormalization() {
        XCTAssertEqual(IntentQueryMapper.grammarQuery(from: "  #link  kind:text \"a b\"\n after:2025-01-01\t"),
                       "#link kind:text \"a b\" after:2025-01-01")
        XCTAssertEqual(IntentQueryMapper.grammarQuery(from: String(repeating: "a", count: 900)).count, IntentQueryMapper.maxQueryLength)
        // The mapped query still goes through the real grammar parser.
        XCTAssertEqual(ClipQueryParser.parse(IntentQueryMapper.grammarQuery(from: "invoice  kind:text")).kinds, [.text])
    }

    func testLimitClamp() {
        XCTAssertEqual(IntentQueryMapper.clampedLimit(nil), 10)
        XCTAssertEqual(IntentQueryMapper.clampedLimit(0), 1)
        XCTAssertEqual(IntentQueryMapper.clampedLimit(9999), IntentQueryMapper.maxResults)
    }

    func testSensitiveExclusion() {
        let clips = [clip("public note"), clip("4111 1111 1111 1111", id: 2)]
        let visible = IntentQueryMapper.visible(clips) { $0.contentText.hasPrefix("4111") }
        XCTAssertEqual(visible.map(\.contentText), ["public note"])
        XCTAssertEqual(ClipSpotlightIndexer.indexable(clips) { $0.id == 2 }.map(\.id), [1])
        XCTAssertTrue(ClipSpotlightIndexer.indexable([clip("x", id: nil), clip("i", kind: .image)]) { _ in false }.isEmpty)
    }

    func testTitles() {
        XCTAssertEqual(IntentQueryMapper.title(for: clip("first line\nsecond")), "first line")
        XCTAssertEqual(IntentQueryMapper.title(for: clip("body", title: "Mine")), "Mine")
        XCTAssertEqual(IntentQueryMapper.title(for: clip("   ")), "Text clip")
        XCTAssertEqual(ClipSpotlightIndexer.identifier(for: 5), "clip-5")
    }
}
