import XCTest
@testable import Clippy

final class IntegrationUIMenuTests: XCTestCase {
    private func clip(_ kind: ClipContentKind, text: String = "hello") -> Clip {
        Clip(id: 1, contentText: text, contentRTF: nil, contentHTML: nil, typeIdentifier: "public.utf8-plain-text",
             sourceAppBundleID: nil, sourceAppName: nil, createdAt: Date(), contentKind: kind)
    }

    func testSensitiveClipGetsNoFeatureItems() {
        XCTAssertTrue(ClipFeatureMenuPolicy.items(for: clip(.text), isSensitive: true).isEmpty)
        XCTAssertTrue(ClipFeatureMenuPolicy.items(for: clip(.image), isSensitive: true).isEmpty)
    }

    func testTextClipItems() {
        let items = ClipFeatureMenuPolicy.items(for: clip(.text), isSensitive: false)
        XCTAssertTrue(items.isSuperset(of: [.transform, .saveSnippet, .translate, .pasteStack, .appendClipboard, .suggestCategory]))
        XCTAssertFalse(items.contains(.describeImage))
    }

    func testEmptyTextClipHasNoTransformOrSnippet() {
        let items = ClipFeatureMenuPolicy.items(for: clip(.text, text: ""), isSensitive: false)
        XCTAssertFalse(items.contains(.transform))
        XCTAssertFalse(items.contains(.saveSnippet))
    }

    func testImageAndFileClipItems() {
        XCTAssertEqual(ClipFeatureMenuPolicy.items(for: clip(.image), isSensitive: false), [.quickLook, .pasteStack, .describeImage])
        XCTAssertEqual(ClipFeatureMenuPolicy.items(for: clip(.file), isSensitive: false), [.quickLook, .pasteStack])
    }

    func testSemanticGateOnlyForOptedInFreeText() {
        XCTAssertTrue(SemanticSearchGate.shouldRun(query: "quarterly report", optedIn: true))
        XCTAssertFalse(SemanticSearchGate.shouldRun(query: "quarterly report", optedIn: false))
        XCTAssertFalse(SemanticSearchGate.shouldRun(query: "\"exact phrase\"", optedIn: true))
        XCTAssertFalse(SemanticSearchGate.shouldRun(query: "#image", optedIn: true))
        XCTAssertFalse(SemanticSearchGate.shouldRun(query: "   ", optedIn: true))
    }

    func testMergeKeepsFusedOrderAndResolvesSemanticOnlyHits() {
        var first = clip(.text, text: "first"); first.id = 1
        var second = clip(.text, text: "second"); second.id = 2
        let results = [SemanticSearchResult(clipID: 2, score: 1, matchedIn: .semantic),
                       SemanticSearchResult(clipID: 1, score: 0.5, matchedIn: .fullText),
                       SemanticSearchResult(clipID: 99, score: 0.1, matchedIn: .semantic)]
        let merged = SemanticSearchGate.merge(results, keyword: [first], pool: [2: second])
        XCTAssertEqual(merged.map(\.id), [2, 1])
    }
}
