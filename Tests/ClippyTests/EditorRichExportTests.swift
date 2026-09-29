import AppKit
import XCTest
@testable import Clippy

@MainActor
final class EditorRichExportTests: XCTestCase {
    func testSanitizeHTMLRemovesNetworkAndScriptVectors() {
        let html = """
        <html><head><link rel="stylesheet" href="https://x/y.css"><style>@import url(https://x);</style>
        <script>evil()</script></head><body onload="x()"><img src="https://t/p.gif"><p style="background:url(https://a)">Hi</p>
        <iframe src="https://z"></iframe></body></html>
        """
        let clean = RichTextConverter.sanitizeHTML(html)
        for banned in ["<script", "<link", "<img", "<iframe", "https://", "onload", "<style"] {
            XCTAssertFalse(clean.lowercased().contains(banned), "\(banned) survived: \(clean)")
        }
        XCTAssertTrue(clean.contains("Hi"))
    }

    func testRTFRoundTripKeepsTextAndBold() throws {
        let source = NSMutableAttributedString(string: "Hello bold world",
                                               attributes: [.font: NSFont.systemFont(ofSize: 13)])
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 6, length: 4))
        let rtf = try XCTUnwrap(RichTextConverter.rtfData(from: source))
        let loaded = try XCTUnwrap(RichTextConverter.attributedString(rtf: rtf, html: nil))
        XCTAssertEqual(loaded.string, "Hello bold world")
        let swiftUI = RichTextConverter.swiftUIValue(from: loaded)
        XCTAssertEqual(String(swiftUI.characters), "Hello bold world")
        let back = RichTextConverter.appKitValue(from: swiftUI)
        let font = back.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(font)).contains(.boldFontMask))
    }

    func testHTMLPreviewParsesSanitizedContent() throws {
        let html = Data("<p>Hello <b>there</b><img src=\"https://t/p.gif\"></p>".utf8)
        let value = try XCTUnwrap(RichTextConverter.attributedString(rtf: nil, html: html))
        XCTAssertTrue(value.string.contains("Hello there"))
        XCTAssertNil(RichTextConverter.attributedString(rtf: nil, html: nil))
    }

    func testExportFormatsAndNames() throws {
        XCTAssertEqual(EditorExportFormat(fileExtension: "MD"), .markdown)
        XCTAssertEqual(EditorExportFormat(fileExtension: "weird"), .text)
        XCTAssertEqual(EditorExport.suggestedName(title: "a/b:c", format: .rtf), "a b c.rtf")
        XCTAssertEqual(EditorExport.suggestedName(title: "  ", format: .html), "Clip.html")
        XCTAssertEqual(EditorExport.data(text: "é", rich: nil, format: .text), Data("é".utf8))
        let rtf = try XCTUnwrap(EditorExport.data(text: "abc", rich: nil, format: .rtf))
        XCTAssertTrue(String(decoding: rtf.prefix(5), as: UTF8.self).hasPrefix("{\\rtf"))
        let html = String(decoding: try XCTUnwrap(EditorExport.data(text: "a<b>&", rich: nil, format: .html)), as: UTF8.self)
        XCTAssertTrue(html.contains("a&lt;b&gt;&amp;"))
    }

    func testSaveRichWritesRTFAndDropsHTML() throws {
        let db = try makeTestDatabase(self)
        let id = try db.insertTextClip("orig")
        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE clips SET contentHTML = ?, contentRTF = ? WHERE id = ?",
                             arguments: [Data("<b>x</b>".utf8), Data("old".utf8), id])
        }
        let persistence = ClipEditorPersistence(database: db)
        let rtf = try XCTUnwrap(RichTextConverter.rtfData(from: NSAttributedString(string: "edited")))
        try persistence.saveRich(id: id, text: "edited", rtf: rtf, title: " T ")
        let clip = try XCTUnwrap(persistence.fetch(id: id))
        XCTAssertEqual(clip.contentText, "edited")
        XCTAssertEqual(clip.contentRTF, rtf)
        XCTAssertNil(clip.contentHTML)
        XCTAssertEqual(clip.userTitle, "T")
        // Title untouched when nil; plain save clears rich blobs again.
        try persistence.saveRich(id: id, text: "again", rtf: rtf, title: nil)
        XCTAssertEqual(persistence.fetch(id: id)?.userTitle, "T")
        try persistence.save(id: id, text: "plain", title: nil)
        XCTAssertNil(persistence.fetch(id: id)?.contentRTF)
    }
}
