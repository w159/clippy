import XCTest
@testable import Clippy

final class SearchGrammarTests: XCTestCase {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // 2025-06-15 12:00 UTC
    private let now = Date(timeIntervalSince1970: TimeInterval(1_750_000_000 - 1_750_000_000 % 86_400 + 12 * 3600))

    private func parse(_ raw: String) -> ParsedQuery { ClipQueryParser.parse(raw, now: now, calendar: cal) }
    private func day(_ string: String) -> Date {
        let parts = string.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    func testQuotedPhrase() {
        let p = parse("\"wire transfer\" invoice")
        XCTAssertEqual(p.phrases, ["wire transfer"])
        XCTAssertEqual(p.text, "invoice")
    }

    func testEscapedQuoteInsidePhrase() {
        XCTAssertEqual(parse(#""say \"hi\" now""#).phrases, [#"say "hi" now"#])
    }

    func testUnterminatedQuoteWarnsButKeepsPhrase() {
        let p = parse("\"open ended")
        XCTAssertEqual(p.phrases, ["open ended"])
        XCTAssertEqual(p.warnings.map(\.kind), [.unterminatedQuote])
    }

    func testNegation() {
        let p = parse("foo -bar -\"a b\" -#image -kind:link -app:chrome -in:Work")
        XCTAssertEqual(p.text, "foo")
        XCTAssertEqual(p.excludedTerms, ["bar"])
        XCTAssertEqual(p.excludedPhrases, ["a b"])
        XCTAssertEqual(p.excludedKinds, [.image, .link])
        XCTAssertEqual(p.excludedApps, ["chrome"])
        XCTAssertEqual(p.excludedCategories, ["Work"])
    }

    func testLoneDashAndInnerDashAreNotNegation() {
        let p = parse("- e-mail")
        XCTAssertEqual(p.text, "e-mail")
        XCTAssertTrue(p.excludedTerms.isEmpty)
    }

    func testEscapedLeadingDashAndHashAreLiteral() {
        let p = parse("\\-foo \\#bar")
        XCTAssertEqual(p.text, "-foo #bar")
        XCTAssertTrue(p.excludedTerms.isEmpty)
        XCTAssertTrue(p.sourceApps.isEmpty)
    }

    func testKindAppInOperators() {
        let p = parse("kind:image,link app:\"Visual Studio\" in:Work")
        XCTAssertEqual(p.kinds, [.image, .link])
        XCTAssertEqual(p.sourceApps, ["visual studio"])
        XCTAssertEqual(p.categories, ["Work"])
    }

    func testUnknownOperatorIsWord() {
        XCTAssertEqual(parse("https://example.com foo:bar").text, "https://example.com foo:bar")
    }

    func testMalformedOperatorsWarn() {
        XCTAssertEqual(parse("kind:").warnings.map(\.kind), [.emptyOperatorValue])
        XCTAssertEqual(parse("kind:banana").warnings.map(\.kind), [.unknownKind])
        XCTAssertEqual(parse("after:notadate").warnings.map(\.kind), [.invalidDate])
        XCTAssertEqual(parse("on:2025-02-31").warnings.map(\.kind), [.invalidDate])
        XCTAssertEqual(parse("size:>lots").warnings.map(\.kind), [.invalidSize])
        XCTAssertEqual(parse("-after:2025-01-01").warnings.map(\.kind), [.unsupportedNegation])
        XCTAssertEqual(parse("after:2025-01-01..2025-02-01").warnings.map(\.kind), [.invalidDate])
    }

    func testUnsearchableWordWarnsInsteadOfVanishing() {
        let p = parse("!!! foo")
        XCTAssertEqual(p.warnings.map(\.kind), [.unsearchableText])
        XCTAssertEqual(p.warnings.first?.token, "!!!")
        XCTAssertFalse(p.warnings.first!.message.isEmpty)
    }

    func testDateOperators() {
        XCTAssertEqual(parse("after:2025-06-01").since, day("2025-06-01"))
        XCTAssertEqual(parse("before:2025-06-01").until, day("2025-06-01"))
        let on = parse("on:2025-06-01")
        XCTAssertEqual(on.since, day("2025-06-01"))
        XCTAssertEqual(on.until, day("2025-06-02"))
        let month = parse("on:2025-06")
        XCTAssertEqual(month.since, day("2025-06-01"))
        XCTAssertEqual(month.until, day("2025-07-01"))
        let range = parse("on:2025-06-01..2025-06-30")
        XCTAssertEqual(range.since, day("2025-06-01"))
        XCTAssertEqual(range.until, day("2025-07-01"))
        XCTAssertNil(parse("on:2025-06-01..").until)
        XCTAssertEqual(parse("on:..2025-06-30").until, day("2025-07-01"))
    }

    func testOperatorsIntersect() {
        let p = parse("after:2025-06-01 before:2025-06-10 after:2025-06-03")
        XCTAssertEqual(p.since, day("2025-06-03"))
        XCTAssertEqual(p.until, day("2025-06-10"))
        XCTAssertEqual(parse("after:2025-06-10 before:2025-06-01").warnings.map(\.kind), [.emptyDateRange])
    }

    func testYesterdayExcludesToday() {
        let p = parse("#yesterday")
        XCTAssertEqual(p.since, day("2025-06-14"))
        XCTAssertEqual(p.until, day("2025-06-15"))
        XCTAssertNil(parse("#today").until)
        // Widest window wins, and an open-ended window keeps the union open.
        XCTAssertNil(parse("#yesterday #today").until)
    }

    func testSizeOperators() {
        XCTAssertEqual(parse("size:>10kb").sizeConstraints, [SizeConstraint(op: .gt, bytes: 10_240)])
        XCTAssertEqual(parse("size:<=1mb").sizeConstraints, [SizeConstraint(op: .le, bytes: 1_048_576)])
        XCTAssertEqual(parse("size:500").sizeConstraints, [SizeConstraint(op: .eq, bytes: 500)])
        XCTAssertEqual(parse("size:1.5k").sizeConstraints, [SizeConstraint(op: .eq, bytes: 1536)])
        XCTAssertEqual(parse("size:1kb..2kb").sizeConstraints.count, 2)
        XCTAssertEqual(parse("-size:>1kb").sizeConstraints, [SizeConstraint(op: .le, bytes: 1024)])
        XCTAssertEqual(parse("-size:=1kb").warnings.map(\.kind), [.unsupportedNegation])
    }

    func testLegacyTokensStillWork() {
        let p = parse("invoice #edge #image #2weeks")
        XCTAssertEqual(p.text, "invoice")
        XCTAssertEqual(p.sourceApps, ["edge"])
        XCTAssertEqual(p.kinds, [.image])
        XCTAssertNotNil(p.since)
    }

    // MARK: - Highlight

    func testHighlightIsCaseAndDiacriticInsensitive() {
        let text = "Café CAFE cafe\u{301}"
        let ranges = SearchHighlight.ranges(in: text, for: "cafe")
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(text[ranges[2]], "cafe\u{301}")
    }

    func testHighlightPhrasesMergeAndIgnoreNegations() {
        let text = "wire transfer done"
        let ranges = SearchHighlight.ranges(in: text, for: "\"wire transfer\" wire -done kind:text")
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["wire transfer"])
    }

    func testHighlightEmojiAndNoMatch() {
        let text = "ship 🚀 now"
        XCTAssertEqual(SearchHighlight.ranges(in: text, for: "🚀").map { String(text[$0]) }, ["🚀"])
        XCTAssertTrue(SearchHighlight.ranges(in: text, for: "zzz").isEmpty)
        XCTAssertTrue(SearchHighlight.ranges(in: text, for: "").isEmpty)
    }

    // MARK: - Filter model

    func testFilterRoundTripsThroughGrammar() {
        let filter = SearchFilter(kinds: [.image, .link], apps: ["visual studio"],
                                  after: day("2025-06-01"), before: day("2025-06-08"), categoryIDs: [7])
        let query = filter.queryString(calendar: cal) { $0 == 7 ? "My Work" : nil }
        XCTAssertEqual(query, "kind:image,link app:\"visual studio\" in:\"My Work\" on:2025-06-01..2025-06-07")
        let back = SearchFilter(parsing: query, now: now, calendar: cal) { $0 == "My Work" ? 7 : nil }
        XCTAssertEqual(back, filter)
    }

    func testAppliedKeepsFreeTextAndNegationsReplacesFilters() {
        let filter = SearchFilter(kinds: [.text])
        let result = filter.applied(to: "invoice -draft #image app:chrome size:>1kb", now: now, calendar: cal)
        XCTAssertEqual(result, "invoice -draft size:>1kb kind:text")
    }
}
