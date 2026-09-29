import XCTest
@testable import Clippy

final class SnippetTemplateTests: XCTestCase {
    private func context() -> SnippetContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var ctx = SnippetContext()
        ctx.now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        ctx.calendar = calendar
        ctx.locale = Locale(identifier: "en_US_POSIX")
        ctx.clipboard = "CLIP"
        ctx.makeUUID = { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        ctx.randomInt = { _ in 7 }
        ctx.environment = ["HOME": "/h"]
        return ctx
    }

    func testDatesUseInjectedClock() {
        XCTAssertEqual(SnippetTemplate.expand("{date}", context: context()).text, "2023-11-14")
        XCTAssertEqual(SnippetTemplate.expand("{date:dd/MM/yyyy}", context: context()).text, "14/11/2023")
        XCTAssertEqual(SnippetTemplate.expand("{time}", context: context()).text, "22:13")
    }

    func testClipboardUuidRandom() {
        XCTAssertEqual(SnippetTemplate.expand("a {clipboard} b", context: context()).text, "a CLIP b")
        XCTAssertEqual(SnippetTemplate.expand("{uuid}", context: context()).text, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(SnippetTemplate.expand("{random:4}", context: context()).text, "7777")
        XCTAssertEqual(SnippetTemplate.expand("{random:0}{random:99}{random:x}", context: context()).text, "{random:0}{random:99}{random:x}")
    }

    func testCursorOffsetCountsCharactersFromEnd() {
        let result = SnippetTemplate.expand("Hi {cursor}there😀", context: context())
        XCTAssertEqual(result.text, "Hi there😀")
        XCTAssertEqual(result.cursorOffsetFromEnd, 6)
        XCTAssertNil(SnippetTemplate.expand("none", context: context()).cursorOffsetFromEnd)
        XCTAssertEqual(SnippetTemplate.expand("a{cursor}b{cursor}c", context: context()).cursorOffsetFromEnd, 2)
    }

    func testFillFieldsOrderedAndDeduplicated() {
        var ctx = context()
        ctx.fillValues = ["Name": "Ann"]
        let result = SnippetTemplate.expand("{fill:Name} {fill:City} {fill:Name}", context: ctx)
        XCTAssertEqual(result.fields, ["Name", "City"])
        XCTAssertEqual(result.text, "Ann  Ann")
        XCTAssertEqual(SnippetTemplate.fillFields(in: "{fill:B}{fill:A}"), ["B", "A"])
        XCTAssertEqual(SnippetTemplate.expand("{fill:}", context: ctx).text, "{fill:}")
    }

    func testEnvDisabledByDefault() {
        XCTAssertEqual(SnippetTemplate.expand("{env:HOME}", context: context()).text, "{env:HOME}")
        var ctx = context()
        ctx.allowEnvironment = true
        XCTAssertEqual(SnippetTemplate.expand("{env:HOME}{env:NOPE}", context: ctx).text, "/h")
    }

    func testLiteralsAndUnknownPlaceholders() {
        XCTAssertEqual(SnippetTemplate.expand("{{date}}", context: context()).text, "{date}")
        XCTAssertEqual(SnippetTemplate.expand("{bogus} { open", context: context()).text, "{bogus} { open")
        XCTAssertEqual(SnippetTemplate.expand("", context: context()).text, "")
        XCTAssertEqual(SnippetTemplate.expand("{clipboard}", context: SnippetContext()).text, "")
    }
}
