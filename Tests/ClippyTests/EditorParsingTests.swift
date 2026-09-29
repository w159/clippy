import XCTest
@testable import Clippy

final class EditorParsingTests: XCTestCase {
    // MARK: CSV

    func testCSVQuotedFieldsAndEscapes() {
        let table = CSVTable.parse("a,b\n\"x,1\",\"he said \"\"hi\"\"\"\n\"multi\nline\",z\n")
        XCTAssertEqual(table?.rows, [["a", "b"], ["x,1", "he said \"hi\""], ["multi\nline", "z"]])
        XCTAssertEqual(table?.delimiter, ",")
    }

    func testCSVDelimiterDetection() {
        XCTAssertEqual(CSVTable.parse("a;b\n1;2")?.delimiter, ";")
        XCTAssertEqual(CSVTable.parse("a\tb\n1\t2")?.delimiter, "\t")
        XCTAssertEqual(CSVTable.parse("a|b\n1|2")?.delimiter, "|")
        XCTAssertNil(CSVTable.parse("just one line, two cells"))
        XCTAssertNil(CSVTable.parse("single\ncolumn"))
    }

    func testCSVRaggedStrictVersusPreview() {
        let text = "a,b,c\n1,2\n3,4,5"
        XCTAssertNil(CSVTable.parse(text))
        let preview = CSVTable.parse(text, requireRectangular: false)
        XCTAssertEqual(preview?.rows.count, 3)
        XCTAssertEqual(preview?.columnCount, 3)
    }

    func testCSVRowCapAndWidths() {
        let body = (0..<300).map { "\($0),v\($0)" }.joined(separator: "\n")
        let table = CSVTable.parse("id,val\n" + body)
        XCTAssertEqual(table?.rows.count, CSVTable.maxRows)
        XCTAssertEqual(table?.truncatedRows, 301 - CSVTable.maxRows)
        let wide = CSVTable.parse("h,x\n\(String(repeating: "w", count: 100)),y")
        XCTAssertEqual(wide?.columnWidths(cap: 40), [40, 1])
    }

    func testCSVColumnCapAndCRLF() {
        let header = (0..<40).map { "c\($0)" }.joined(separator: ",")
        XCTAssertEqual(CSVTable.parse(header + "\r\n" + header)?.rows[0].count, CSVTable.maxColumns)
        XCTAssertEqual(CSVTable.parse("a,b\r\n1,2\r\n")?.rows, [["a", "b"], ["1", "2"]])
    }

    func testCSVPreviewCutsAtLineBoundary() {
        let line = "abcdefghij,klmnopqrst\n"
        let text = String(repeating: line, count: CSVTable.previewCharacterLimit / line.count + 50)
        let table = CSVTable.preview(text)
        XCTAssertNotNil(table)
        XCTAssertTrue(table!.rows.allSatisfy { $0 == ["abcdefghij", "klmnopqrst"] })
    }

    // MARK: Color values

    func testHexParsing() throws {
        let short = try XCTUnwrap(ColorValueParser.parse("#f80"))
        XCTAssertEqual(short.hex, "#FF8800")
        let long = try XCTUnwrap(ColorValueParser.parse(" #336699 "))
        XCTAssertEqual(long.hex, "#336699")
        let alpha = try XCTUnwrap(ColorValueParser.parse("#33669980"))
        XCTAssertEqual(alpha.hex, "#33669980")
        XCTAssertNil(ColorValueParser.parse("#12"))
        XCTAssertNil(ColorValueParser.parse("#ggg"))
        XCTAssertNil(ColorValueParser.parse("red"))
    }

    func testRGBAndHSL() throws {
        XCTAssertEqual(ColorValueParser.parse("rgb(255, 0, 128)")?.hex, "#FF0080")
        XCTAssertEqual(ColorValueParser.parse("rgb(100%, 0%, 0%)")?.hex, "#FF0000")
        XCTAssertEqual(ColorValueParser.parse("rgba(0, 0, 255, 0.5)")?.hex, "#0000FF80")
        XCTAssertEqual(ColorValueParser.parse("hsl(120, 100%, 50%)")?.hex, "#00FF00")
        XCTAssertEqual(ColorValueParser.parse("hsl(0 0% 100%)")?.hex, "#FFFFFF")
        XCTAssertEqual(ColorValueParser.parse("hsl(-120, 100%, 50%)")?.hex, "#0000FF")
        XCTAssertEqual(ColorValueParser.parse("rgb(999, -5, 0)")?.hex, "#FF0000")
        XCTAssertNil(ColorValueParser.parse("rgb(1, 2)"))
        XCTAssertNil(ColorValueParser.parse("rgb(a, b, c)"))
    }

    func testFindDedupesLimitsAndSkipsHugeText() {
        let text = "bg: #fff; fg: #FFFFFF; border: rgb(1,2,3); x: #abcdef12; not: #12345"
        XCTAssertEqual(ColorValueParser.find(in: text).map(\.hex), ["#FFFFFF", "#010203", "#ABCDEF12"])
        let many = (0..<30).map { String(format: "#%06X", $0 * 1000) }.joined(separator: " ")
        XCTAssertEqual(ColorValueParser.find(in: many, limit: 5).count, 5)
        XCTAssertTrue(ColorValueParser.find(in: "#fff", maxScan: 2).isEmpty)
    }
}
