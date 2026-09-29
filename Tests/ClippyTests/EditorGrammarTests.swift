import XCTest
@testable import Clippy

final class EditorGrammarTests: XCTestCase {
    private func tokens(_ text: String, _ language: CodeLanguage) -> [(CodeTokenKind, String)] {
        let ns = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: language).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func has(_ list: [(CodeTokenKind, String)], _ kind: CodeTokenKind, _ text: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(list.contains { $0.0 == kind && $0.1 == text }, "missing \(kind) \(text) in \(list)", file: file, line: line)
    }

    func testMarkdownBlocksAndInline() {
        let text = "# Title\n\n- item\n> quote\n\nSome `code` and **bold** and [link](http://x.io).\n\n```swift\nlet a = 1 # not heading\n```\n"
        let list = tokens(text, .markdown)
        has(list, .keyword, "# Title")
        has(list, .op, "- ")
        has(list, .comment, "> quote")
        has(list, .string, "`code`")
        has(list, .type, "**bold**")
        has(list, .function, "[link](http://x.io)")
        XCTAssertTrue(list.contains { $0.0 == .string && $0.1.hasPrefix("```swift") && $0.1.contains("# not heading") })
        XCTAssertFalse(list.contains { $0.0 == .keyword && $0.1.contains("not heading") })
    }

    func testMarkdownUnterminatedFenceRunsToEnd() {
        let list = tokens("```\nabc\n# x", .markdown)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].0, .string)
    }

    func testSQL() {
        let list = tokens("SELECT count(*) FROM users WHERE name = 'O''Brien' -- c\nAND id > 42;", .sql)
        has(list, .keyword, "SELECT")
        has(list, .function, "count")
        has(list, .keyword, "FROM")
        has(list, .string, "'O''Brien'")
        has(list, .comment, "-- c")
        has(list, .number, "42")
        XCTAssertFalse(tokens("selected", .sql).contains { $0.0 == .keyword })
    }

    func testMarkup() {
        let list = tokens("<!-- c --><div class=\"a b\" id='x'>Tom &amp; \"Jerry\"</div>", .markup)
        has(list, .comment, "<!-- c -->")
        has(list, .keyword, "<div")
        has(list, .attribute, "class")
        has(list, .string, "\"a b\"")
        has(list, .string, "'x'")
        has(list, .variable, "&amp;")
        has(list, .keyword, "</div")
        XCTAssertFalse(list.contains { $0.1 == "\"Jerry\"" }, "prose quotes are not attribute values")
    }

    func testMarkupDoctypeAndCDATA() {
        let list = tokens("<?xml version=\"1.0\"?><a><![CDATA[x < y]]></a>", .markup)
        has(list, .attribute, "<?xml version=\"1.0\"?>")
        has(list, .string, "<![CDATA[x < y]]>")
    }

    func testCSV() {
        let list = tokens("name,qty\n\"a,b\",3\nc,-4.5\n", .csv)
        has(list, .keyword, "name,qty")
        has(list, .string, "\"a,b\"")
        has(list, .number, "3")
        has(list, .number, "-4.5")
        has(list, .op, ",")
    }

    func testJSONStillHighlightsKeysAndLiterals() {
        let list = tokens("{\"k\": [1, true, null, \"v\"]}", .json)
        has(list, .attribute, "\"k\"")
        has(list, .keyword, "null")
        has(list, .string, "\"v\"")
    }

    func testEveryLanguageHasCommentPrefixDecision() {
        XCTAssertEqual(CodeLanguage.sql.lineComment, "--")
        XCTAssertNil(CodeLanguage.markdown.lineComment)
        for language in CodeLanguage.allCases { XCTAssertFalse(language.displayName.isEmpty) }
    }
}
