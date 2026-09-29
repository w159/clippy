import XCTest
@testable import Clippy

final class EditorSnifferTests: XCTestCase {
    func testLanguageTable() {
        let cases: [(String, CodeLanguage)] = [
            ("", .plain),
            ("   \n ", .plain),
            ("Just a normal sentence about lunch.", .plain),
            ("Let me know what you think, thanks", .plain),
            ("{\"a\": 1, \"b\": [true, null]}", .json),
            ("[1, 2, 3]", .json),
            ("{\"name\": \"x\",\n \"items\": [", .json),
            ("{ let x = 1 }", .plain),
            ("<?xml version=\"1.0\"?><root><a/></root>", .markup),
            ("<!DOCTYPE html><html><body>hi</body></html>", .markup),
            ("<div class=\"a\">hello</div>", .markup),
            ("#!/usr/bin/env python3\nprint('x')", .python),
            ("#!/bin/bash\necho hi", .shell),
            ("#!/usr/bin/env node\nconsole.log(1)", .javascript),
            ("def add(a, b):\n    return a + b\n", .python),
            ("import os\nfrom sys import argv\n", .python),
            ("import SwiftUI\n\nstruct A: View {\n    var body: some View { Text(\"x\") }\n}", .swift),
            ("guard let x = y else { return }\nlet z = 1", .swift),
            ("SELECT id, name FROM users WHERE id = 1;", .sql),
            ("INSERT INTO t (a) VALUES (1);", .sql),
            ("sudo apt-get install foo", .shell),
            ("export PATH=\"$HOME/bin:$PATH\"\ncd ~/src && ls", .shell),
            ("# Title\n\nSome text with a [link](https://a.io) and **bold**.", .markdown),
            ("```\ncode\n```\n- one\n- two", .markdown),
            ("name,age\nAnn,3\nBob,4\n", .csv),
            ("a;b;c\n1;2;3", .csv),
            ("a\tb\n1\t2", .csv),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(EditorLanguageSniffer.detect(text), expected, "for: \(text.debugDescription)")
        }
    }

    func testRaggedCommasAreNotCSV() {
        XCTAssertEqual(EditorLanguageSniffer.detect("hello, world\nsecond line, with, more commas"), .plain)
    }

    func testSingleValueKindsAreNeverHighlighted() {
        for text in ["#FF8800", "https://example.com/a?b=1", "me@example.com", "/usr/local/bin"] {
            XCTAssertEqual(EditorLanguageSniffer.language(forText: text), .plain, text)
        }
        XCTAssertEqual(EditorLanguageSniffer.language(forText: "{\"a\": 1}"), .json)
    }
}
