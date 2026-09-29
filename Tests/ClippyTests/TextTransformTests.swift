import XCTest
@testable import Clippy

final class TextTransformTests: XCTestCase {
    private func run(_ id: String, _ input: String) throws -> String {
        try XCTUnwrap(TransformRegistry.transform(id: id), id).apply(input)
    }

    func testCaseTransforms() throws {
        XCTAssertEqual(try run("case.upper", "straße"), "STRASSE")
        XCTAssertEqual(try run("case.title", "hello wORLD it's"), "Hello World It's")
        XCTAssertEqual(try run("case.sentence", "hello. wORLD! ok"), "Hello. World! Ok")
        XCTAssertEqual(try run("case.camel", "Hello big_world-foo"), "helloBigWorldFoo")
        XCTAssertEqual(try run("case.snake", "HTTPServerError"), "http_server_error")
        XCTAssertEqual(try run("case.kebab", "fooBar baz"), "foo-bar-baz")
        XCTAssertEqual(try run("case.constant", "fooBar baz"), "FOO_BAR_BAZ")
        XCTAssertEqual(try run("case.snake", "café Crème"), "café_crème")
        for item in CaseTransforms.all { XCTAssertEqual(try item.apply(""), "") }
    }

    func testCleanup() throws {
        XCTAssertEqual(try run("cleanup.trim", "  a b \n"), "a b")
        XCTAssertEqual(try run("cleanup.collapse", " a \n\t b   c "), "a b c")
        XCTAssertEqual(try run("cleanup.quote", "say \"hi\"\n"), "\"say \\\"hi\\\"\\n\"")
        XCTAssertEqual(try run("cleanup.unquote", "\"a\\nb\""), "a\nb")
        XCTAssertEqual(try run("cleanup.unquote", "'it'"), "it")
        XCTAssertThrowsError(try run("cleanup.unquote", "plain"))
        XCTAssertEqual(try run("unescape.json", try run("escape.json", "a\"b\\c\n\u{1}é😀")), "a\"b\\c\n\u{1}é😀")
        XCTAssertEqual(try run("unescape.json", "\\ud83d\\ude00"), "😀")
        XCTAssertEqual(try run("escape.shell", "it's"), "'it'\\''s'")
        XCTAssertEqual(try run("unescape.shell", "'it'\\''s'"), "it's")
        XCTAssertEqual(try run("cleanup.striphtml", "<p>Hi <b>there</b> &amp; you<script>x()</script></p>"), "Hi there & you")
    }

    func testJSON() throws {
        XCTAssertEqual(try run("json.minify", "{ \"a\": [1, 2] }\n"), "{\"a\":[1,2]}")
        XCTAssertEqual(try run("json.pretty", "{\"a\":1}"), "{\n  \"a\" : 1\n}")
        XCTAssertEqual(try run("json.validate", "[1,2]"), "Valid JSON")
        XCTAssertEqual(try run("json.pretty", "\"x\""), "\"x\"")
        do {
            _ = try run("json.validate", "{\n  \"a\": 1,\n  \"b\": }")
            XCTFail("expected failure")
        } catch let TransformError.invalidInput(_, line, column) {
            XCTAssertEqual(line, 3)
            XCTAssertNotNil(column)
        }
        XCTAssertThrowsError(try run("json.pretty", ""))
    }

    func testEncodings() throws {
        XCTAssertEqual(try run("base64.encode", "héllo"), "aMOpbGxv")
        XCTAssertEqual(try run("base64.decode", "aMOpbGxv"), "héllo")
        XCTAssertEqual(try run("base64.decode", "aMOpbGxv\n"), "héllo")
        XCTAssertEqual(try run("base64.decode", "YQ"), "a")
        XCTAssertThrowsError(try run("base64.decode", "!!!"))
        XCTAssertThrowsError(try run("base64.decode", "/w=="))
        XCTAssertEqual(try run("url.encode", "a b&c=é/~"), "a%20b%26c%3D%C3%A9%2F~")
        XCTAssertEqual(try run("url.decode", "a%20b%26"), "a b&")
        XCTAssertThrowsError(try run("url.decode", "%zz"))
        XCTAssertEqual(try run("html.encode", "<a href=\"x\">&'</a>"), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;")
        XCTAssertEqual(try run("html.decode", "&lt;&amp;&#65;&#x42;&bogus;&nbsp;"), "<&AB&bogus;\u{00A0}")
    }

    func testHashes() throws {
        XCTAssertEqual(try run("hash.md5", ""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(try run("hash.sha1", "abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(try run("hash.sha256", "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try run("hash.sha512", "abc").prefix(16), "ddaf35a193617aba")
    }

    func testLines() throws {
        XCTAssertEqual(try run("lines.sort.asc", "b\na\nc\n"), "a\nb\nc")
        XCTAssertEqual(try run("lines.sort.desc", "b\na\nc"), "c\nb\na")
        XCTAssertEqual(try run("lines.sort.numeric", "10\nx\n9\n-1\ny"), "-1\n9\n10\nx\ny")
        XCTAssertEqual(try run("lines.sort.ci", "b\nA\nc"), "A\nb\nc")
        XCTAssertEqual(try run("lines.dedupe", "a\nb\na\nc\nb"), "a\nb\nc")
        XCTAssertEqual(try run("lines.reverse", "a\nb\nc"), "c\nb\na")
        XCTAssertEqual(try run("lines.number", "a\nb"), "1. a\n2. b")
        XCTAssertEqual(try run("lines.number", (1...10).map(String.init).joined(separator: "\n")).components(separatedBy: "\n")[0], " 1. 1")
        XCTAssertEqual(try run("lines.sort.asc", ""), "")
        XCTAssertEqual(try run("lines.dedupe", "a\r\na\r\nb"), "a\nb")
    }

    func testExtractAndCount() throws {
        XCTAssertEqual(try run("extract.urls", "see https://a.com/x?y=1 and http://b.org, https://a.com/x?y=1"),
                       "https://a.com/x?y=1\nhttp://b.org,")
        XCTAssertEqual(try run("extract.emails", "a@b.co, x.y+z@mail.example.com"), "a@b.co\nx.y+z@mail.example.com")
        XCTAssertEqual(try run("extract.numbers", "a 12 b -3.5 c 12"), "12\n-3.5")
        XCTAssertEqual(try run("count.stats", "one two\nthree"), "Words: 3, Characters: 13, Lines: 2")
        XCTAssertEqual(try run("count.stats", ""), "Words: 0, Characters: 0, Lines: 0")
    }

    func testTimestamps() throws {
        XCTAssertEqual(try run("date.toiso", "0"), "1970-01-01T00:00:00Z")
        XCTAssertEqual(try run("date.toiso", "1700000000000"), "2023-11-14T22:13:20Z")
        XCTAssertEqual(try run("date.fromiso", "2023-11-14T22:13:20Z"), "1700000000")
        XCTAssertEqual(try run("date.fromiso", "1970-01-02"), "86400")
        XCTAssertThrowsError(try run("date.toiso", "abc"))
        XCTAssertThrowsError(try run("date.fromiso", "yesterday"))
    }

    func testInputCapAndPreview() {
        let huge = String(repeating: "a", count: TransformLimits.maxInputBytes + 1)
        XCTAssertThrowsError(try TransformRegistry.transform(id: "case.upper")!.apply(huge)) {
            XCTAssertEqual($0 as? TransformError, .inputTooLarge(bytes: huge.utf8.count))
        }
        let upper = TransformRegistry.transform(id: "case.upper")!
        let preview = upper.preview(for: String(repeating: "ab", count: 500))
        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThanOrEqual(preview.before.count, TransformLimits.previewCharacters + 1)
        XCTAssertNil(preview.error)
        let failed = TransformRegistry.transform(id: "json.validate")!.preview(for: "{")
        XCTAssertNotNil(failed.error)
    }

    func testRegistrySearch() {
        XCTAssertEqual(Set(TransformRegistry.all.map(\.id)).count, TransformRegistry.all.count)
        XCTAssertTrue(TransformRegistry.search("base64 dec").contains { $0.id == "base64.decode" })
        XCTAssertEqual(TransformRegistry.search("").count, TransformRegistry.all.count)
        XCTAssertTrue(TransformRegistry.search("zzzzqq").isEmpty)
    }
}
