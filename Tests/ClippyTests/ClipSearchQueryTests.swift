import XCTest
@testable import Clippy

final class ClipSearchQueryTests: XCTestCase {
    // Fixed reference instant so relative-date math is deterministic.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var cal: Calendar { Calendar(identifier: .gregorian) }

    // MARK: - Parser

    func testEmptyQueryIsEmpty() {
        let p = ClipQueryParser.parse("   ", now: now, calendar: cal)
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.text, "")
        XCTAssertTrue(p.sourceApps.isEmpty)
        XCTAssertNil(p.since)
    }

    func testPlainTextOnly() {
        let p = ClipQueryParser.parse("quarterly invoice", now: now, calendar: cal)
        XCTAssertEqual(p.text, "quarterly invoice")
        XCTAssertTrue(p.sourceApps.isEmpty)
        XCTAssertNil(p.since)
    }

    func testAppTokenOnly() {
        let p = ClipQueryParser.parse("#edge", now: now, calendar: cal)
        XCTAssertEqual(p.sourceApps, ["edge"])
        XCTAssertEqual(p.text, "")
        XCTAssertNil(p.since)
    }

    func testDurationTokenWeeks() {
        let p = ClipQueryParser.parse("#2weeks", now: now, calendar: cal)
        let expected = cal.date(byAdding: .weekOfYear, value: -2, to: now)!
        XCTAssertEqual(p.since!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(p.sourceApps.isEmpty)
    }

    func testCombinedTextAppDuration() {
        let p = ClipQueryParser.parse("invoice #edge #2weeks", now: now, calendar: cal)
        XCTAssertEqual(p.text, "invoice")
        XCTAssertEqual(p.sourceApps, ["edge"])
        XCTAssertEqual(p.since!.timeIntervalSince1970,
                       cal.date(byAdding: .weekOfYear, value: -2, to: now)!.timeIntervalSince1970,
                       accuracy: 1)
    }

    func testTodayAndYesterday() {
        XCTAssertEqual(ClipQueryParser.parse("#today", now: now, calendar: cal).since,
                       cal.startOfDay(for: now))
        let y = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        XCTAssertEqual(ClipQueryParser.parse("#yesterday", now: now, calendar: cal).since, y)
    }

    func testShortFormsAndDefaultCount() {
        XCTAssertEqual(ClipQueryParser.parse("#3d", now: now, calendar: cal).since!.timeIntervalSince1970,
                       cal.date(byAdding: .day, value: -3, to: now)!.timeIntervalSince1970, accuracy: 1)
        // Bare unit means count 1.
        XCTAssertEqual(ClipQueryParser.parse("#month", now: now, calendar: cal).since!.timeIntervalSince1970,
                       cal.date(byAdding: .month, value: -1, to: now)!.timeIntervalSince1970, accuracy: 1)
    }

    func testUnknownUnitTreatedAsApp() {
        // "#5x" is not a recognized duration, so it is an app filter, not a date.
        let p = ClipQueryParser.parse("#5x", now: now, calendar: cal)
        XCTAssertEqual(p.sourceApps, ["5x"])
        XCTAssertNil(p.since)
    }

    func testMultipleDurationsKeepWidestWindow() {
        // Earliest (widest) lower bound wins.
        let p = ClipQueryParser.parse("#2d #3weeks", now: now, calendar: cal)
        XCTAssertEqual(p.since!.timeIntervalSince1970,
                       cal.date(byAdding: .weekOfYear, value: -3, to: now)!.timeIntervalSince1970,
                       accuracy: 1)
    }

    // MARK: - DB-backed search (the SQL actually filters)

    func testSearchFiltersBySourceApp() throws {
        let db = try makeTestDatabase(self)
        var edge = makeTextClip("alpha receipt")
        edge.sourceAppName = "Microsoft Edge"
        edge.sourceAppBundleID = "com.microsoft.edgemac"
        var other = makeTextClip("beta receipt")
        other.sourceAppName = "Notes"
        other.sourceAppBundleID = "com.apple.notes"
        try db.saveCapturedClip(&edge, cap: 1000)
        try db.saveCapturedClip(&other, cap: 1000)

        let results = try db.searchClips(matching: "#edge", limit: 50)
        XCTAssertEqual(results.map(\.sourceAppName), ["Microsoft Edge"])
    }

    func testSearchFiltersByDuration() throws {
        let db = try makeTestDatabase(self)
        var recent = makeTextClip("fresh", createdAt: Date())
        var old = makeTextClip("stale", createdAt: Date().addingTimeInterval(-20 * 24 * 3600))
        try db.saveCapturedClip(&recent, cap: 1000)
        try db.saveCapturedClip(&old, cap: 1000)

        let results = try db.searchClips(matching: "#2weeks", limit: 50)
        let texts = results.map(\.contentText)
        XCTAssertTrue(texts.contains("fresh"))
        XCTAssertFalse(texts.contains("stale"))
    }

    func testSearchCombinesAppAndText() throws {
        let db = try makeTestDatabase(self)
        var edgeInvoice = makeTextClip("invoice march")
        edgeInvoice.sourceAppName = "Microsoft Edge"
        var edgeOther = makeTextClip("recipe ideas")
        edgeOther.sourceAppName = "Microsoft Edge"
        try db.saveCapturedClip(&edgeInvoice, cap: 1000)
        try db.saveCapturedClip(&edgeOther, cap: 1000)

        let results = try db.searchClips(matching: "invoice #edge", limit: 50)
        XCTAssertEqual(results.map(\.contentText), ["invoice march"])
    }

    // MARK: - Kind tokens

    func testKindTokenParsing() {
        let p = ClipQueryParser.parse("#image #url receipts", now: now, calendar: cal)
        XCTAssertEqual(p.kinds, [.image, .link])
        XCTAssertEqual(p.text, "receipts")
        XCTAssertTrue(p.sourceApps.isEmpty)
        XCTAssertNil(p.since)
    }

    func testUnrecognizedTokenStillFallsThroughToApp() {
        let p = ClipQueryParser.parse("#slack", now: now, calendar: cal)
        XCTAssertEqual(p.sourceApps, ["slack"])
        XCTAssertTrue(p.kinds.isEmpty)
    }

    func testSearchFiltersByStoredKind() throws {
        let db = try makeTestDatabase(self)
        var text = makeTextClip("some words")
        var image = makeTextClip("")
        image.contentKind = .image
        image.typeIdentifier = "public.png"
        image.mediaFilename = "distinct-image.png"
        try db.saveCapturedClip(&text, cap: 1000)
        try db.saveCapturedClip(&image, cap: 1000)

        let results = try db.searchClips(matching: "#image", limit: 50)
        XCTAssertEqual(results.map(\.contentKind), [.image])
    }

    func testSearchFiltersByDerivedLinkKind() throws {
        let db = try makeTestDatabase(self)
        var url = makeTextClip("https://example.com/report")
        var plain = makeTextClip("plain words only")
        try db.saveCapturedClip(&url, cap: 1000)
        try db.saveCapturedClip(&plain, cap: 1000)

        let results = try db.searchClips(matching: "#link", limit: 50)
        XCTAssertEqual(results.map(\.contentText), ["https://example.com/report"])
    }

    func testSearchCombinesKindAndApp() throws {
        let db = try makeTestDatabase(self)
        var edgeURL = makeTextClip("https://example.com/a")
        edgeURL.sourceAppName = "Microsoft Edge"
        var notesURL = makeTextClip("https://example.com/b")
        notesURL.sourceAppName = "Notes"
        try db.saveCapturedClip(&edgeURL, cap: 1000)
        try db.saveCapturedClip(&notesURL, cap: 1000)

        let results = try db.searchClips(matching: "#link #edge", limit: 50)
        XCTAssertEqual(results.map(\.contentText), ["https://example.com/a"])
    }

    // MARK: - Local (category-pane) matching honors the token grammar

    func testMatchesLocallyKindToken() {
        var image = makeTextClip("")
        image.contentKind = .image
        XCTAssertTrue(image.matchesLocally(query: "#image"))
        XCTAssertFalse(makeTextClip("words").matchesLocally(query: "#image"))
    }

    func testMatchesLocallyAppAndTextTokens() {
        var clip = makeTextClip("quarterly invoice")
        clip.sourceAppName = "Microsoft Edge"
        XCTAssertTrue(clip.matchesLocally(query: "invoice #edge"))
        XCTAssertFalse(clip.matchesLocally(query: "invoice #notes"))
        XCTAssertFalse(clip.matchesLocally(query: "recipe #edge"))
    }
}
