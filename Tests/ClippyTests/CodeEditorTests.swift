import XCTest
@testable import Clippy

/// Pure-function tests for the code editor: tokenizer, line index, indentation, brackets.
final class CodeEditorTests: XCTestCase {
    private func tokens(_ text: String, _ language: CodeLanguage) -> [(CodeTokenKind, String)] {
        let ns = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: language).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func assertHas(_ list: [(CodeTokenKind, String)], _ kind: CodeTokenKind, _ text: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(list.contains { $0.0 == kind && $0.1 == text }, "missing \(kind) '\(text)' in \(list)", file: file, line: line)
    }

    func testShellStringsCommentsVariablesAndKeywordsInsideStringsAreNotKeywords() {
        let t = tokens("if [ \"$x\" ]; then echo 'if' # then\nfi", .shell)
        assertHas(t, .keyword, "if"); assertHas(t, .keyword, "then"); assertHas(t, .keyword, "fi")
        assertHas(t, .string, "\"$x\""); assertHas(t, .string, "'if'"); assertHas(t, .comment, "# then")
        XCTAssertEqual(t.filter { $0.0 == .keyword }.count, 3, "keywords inside strings/comments must not count")
        assertHas(tokens("echo $HOME ${a} $1", .shell), .variable, "$HOME")
    }

    func testShellHashInsideWordIsNotAComment() {
        XCTAssertFalse(tokens("echo a#b ${#x}", .shell).contains { $0.0 == .comment })
    }

    func testPythonTripleQuotedAndDecorators() {
        let t = tokens("@app.route\ndef f():\n    \"\"\"doc\nmore\"\"\"\n    return None  # z", .python)
        assertHas(t, .attribute, "@app.route"); assertHas(t, .keyword, "def"); assertHas(t, .keyword, "None")
        assertHas(t, .string, "\"\"\"doc\nmore\"\"\""); assertHas(t, .comment, "# z")
    }

    func testJavaScriptTemplateAndBlockComments() {
        let t = tokens("const a = `x${1}`; /* c */ // d\nlet B = 0x1F", .javascript)
        assertHas(t, .string, "`x${1}`"); assertHas(t, .comment, "/* c */"); assertHas(t, .comment, "// d")
        assertHas(t, .number, "0x1F"); assertHas(t, .type, "B")
    }

    func testRubySwiftAppleScriptAndJSON() {
        assertHas(tokens("puts :sym, @iv\nend", .ruby), .attribute, ":sym")
        assertHas(tokens("@main struct A { let s = \"x\" } // c", .swift), .attribute, "@main")
        assertHas(tokens("TELL application \"Finder\" -- c", .applescript), .keyword, "TELL")
        let json = tokens("{\"a\": [1, true, \"b\"]}", .json)
        assertHas(json, .attribute, "\"a\""); assertHas(json, .string, "\"b\""); assertHas(json, .keyword, "true")
    }

    func testPlainAndOversizedTextProduceNoTokens() {
        XCTAssertTrue(tokens("if then", .plain).isEmpty)
        XCTAssertTrue(SyntaxHighlighter.tokens(in: String(repeating: "a", count: SyntaxHighlighter.maxHighlightLength + 1),
                                               language: .shell).isEmpty)
    }

    func testTokenRangesAreUTF16AndDoNotOverlap() {
        let text = "echo \"😀 é\" # ü\nif x"
        let result = SyntaxHighlighter.tokens(in: text, language: .shell)
        var end = 0
        for token in result {
            XCTAssertGreaterThanOrEqual(token.range.location, end)
            end = NSMaxRange(token.range)
        }
        XCTAssertLessThanOrEqual(end, (text as NSString).length)
    }

    func testInterpreterMapsToLanguage() {
        for interpreter in ScriptInterpreter.allCases { XCTAssertNotEqual(interpreter.codeLanguage, .plain) }
    }

    func testLineIndex() {
        let index = LineIndex(text: "a\nbb\n\nc\n")
        XCTAssertEqual(index.starts, [0, 2, 5, 6, 8])
        XCTAssertEqual(index.line(containing: 3), 1)
        XCTAssertTrue(index.isLineStart(5)); XCTAssertFalse(index.isLineStart(3))
        XCTAssertEqual(LineIndex(text: "").lineCount, 1)
        XCTAssertEqual(LineIndex(text: "x").lineCount, 1)
    }

    func testNewlineKeepsAndDeepensIndent() {
        XCTAssertEqual(CodeIndentation.newline(in: "  a", cursor: 3, unit: .spaces(4), language: .shell).insert, "\n  ")
        XCTAssertEqual(CodeIndentation.newline(in: "  if x {", cursor: 8, unit: .spaces(4), language: .swift).insert, "\n      ")
        XCTAssertEqual(CodeIndentation.newline(in: "def f():", cursor: 8, unit: .spaces(4), language: .python).insert, "\n    ")
        let between = CodeIndentation.newline(in: "f {}", cursor: 3, unit: .tab, language: .swift)
        XCTAssertEqual(between.insert, "\n\t\n")
        XCTAssertEqual(between.caretOffset, 2)
    }

    func testShiftLinesIndentAndOutdent() {
        let indented = CodeIndentation.shiftLines(in: "a\n\nb\nc", range: NSRange(location: 0, length: 4), unit: .spaces(2), outdent: false)
        XCTAssertEqual(indented.replacement, "  a\n\n  b\n")
        XCTAssertEqual(indented.replacedRange, NSRange(location: 0, length: 5))
        let outdented = CodeIndentation.shiftLines(in: "    a\n\tb\n c", range: NSRange(location: 0, length: 11), unit: .spaces(4), outdent: true)
        XCTAssertEqual(outdented.replacement, "a\nb\nc")
    }

    func testBracketMatching() {
        let text = "f(a[1])" as NSString
        let pair = BracketMatcher.pair(in: text, caret: 2)
        XCTAssertEqual(pair?.0, 1); XCTAssertEqual(pair?.1, 6)
        XCTAssertEqual(BracketMatcher.pair(in: text, caret: 7)?.1, 1, "caret after a closer matches backwards")
        XCTAssertNil(BracketMatcher.pair(in: "f(a" as NSString, caret: 2))
        XCTAssertNil(BracketMatcher.pair(in: "abc" as NSString, caret: 1))
    }
}
