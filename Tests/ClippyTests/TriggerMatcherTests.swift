import XCTest
@testable import Clippy

final class TriggerMatcherTests: XCTestCase {
    private func snip(_ abbr: String, enabled: Bool = true) -> Snippet { Snippet(abbreviation: abbr, title: abbr, body: "x", isEnabled: enabled) }

    private func type(_ text: String, into matcher: inout TriggerMatcher) -> TriggerMatcher.Match? {
        var last: TriggerMatcher.Match?
        for char in text { if let hit = matcher.feed(char) { last = hit } }
        return last
    }

    func testDelimiterModeExpandsOnSpaceReturnTab() {
        for delimiter in [" ", "\n", "\t"] {
            var matcher = TriggerMatcher(snippets: [snip(";sig")], mode: .onDelimiter)
            XCTAssertNil(type(";sig", into: &matcher))
            let hit = matcher.feed(Character(delimiter))
            XCTAssertEqual(hit?.deleteCount, 5)
            XCTAssertEqual(hit?.delimiter, Character(delimiter))
        }
    }

    func testImmediateMode() {
        var matcher = TriggerMatcher(snippets: [snip(";sig")], mode: .immediate)
        let hit = type("hello ;sig", into: &matcher)
        XCTAssertEqual(hit?.deleteCount, 4)
        XCTAssertNil(hit?.delimiter)
        XCTAssertTrue(matcher.buffer.isEmpty)
    }

    func testDelimiterModeRequiresWordBoundary() {
        var matcher = TriggerMatcher(snippets: [snip("br")], mode: .onDelimiter)
        XCTAssertNil(type("abr ", into: &matcher))
        XCTAssertNotNil(type("x br ", into: &matcher))
    }

    func testLongestMatchWins() {
        var matcher = TriggerMatcher(snippets: [snip(";a"), snip(";ab"), snip("b")], mode: .immediate)
        XCTAssertEqual(type(";a", into: &matcher)?.snippet.abbreviation, ";a")
        matcher = TriggerMatcher(snippets: [snip("b"), snip(";ab")], mode: .onDelimiter)
        XCTAssertEqual(type(";ab ", into: &matcher)?.snippet.abbreviation, ";ab")
    }

    func testCaseSensitivity() {
        var strict = TriggerMatcher(snippets: [snip(";Sig")], mode: .onDelimiter, caseSensitive: true)
        XCTAssertNil(type(";sig ", into: &strict))
        var loose = TriggerMatcher(snippets: [snip(";Sig")], mode: .onDelimiter, caseSensitive: false)
        XCTAssertNotNil(type(";sig ", into: &loose))
    }

    func testResetAndBackspace() {
        var matcher = TriggerMatcher(snippets: [snip(";sig")], mode: .immediate)
        _ = type(";si", into: &matcher)
        matcher.reset()
        XCTAssertNil(type("g", into: &matcher))
        _ = type(";sx", into: &matcher)
        matcher.deleteBackward()
        XCTAssertNotNil(type("ig", into: &matcher).map { $0 } ?? nil)
    }

    func testDisabledAndEmptyIgnoredAndBufferBounded() {
        var matcher = TriggerMatcher(snippets: [snip(";off", enabled: false), snip("")], mode: .immediate)
        XCTAssertNil(type(";off", into: &matcher))
        for _ in 0..<500 { _ = matcher.feed("z") }
        XCTAssertEqual(matcher.buffer.count, TriggerMatcher.bufferLimit)
        var other = TriggerMatcher(snippets: [snip(";x")], mode: .onDelimiter)
        XCTAssertNil(type("hello ", into: &other))
    }
}
