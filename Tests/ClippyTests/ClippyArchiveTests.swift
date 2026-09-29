import XCTest
@testable import Clippy

@MainActor
final class ClippyArchiveTests: XCTestCase {

    func testExportImportRoundTrip() throws {
        let source = try makeTestDatabase(self)
        let work = try source.createCategory(
            named: "Work", colorHex: "#007AFF", iconKind: .symbol, iconValue: "briefcase.fill"
        )
        let workID = try XCTUnwrap(work.id)

        // Include a multi-line clip with a quote to exercise string escaping.
        let multiline = "func main() {\n    print(\"hi\")\n}"
        var c1 = makeTextClip("swift build"); try source.saveCapturedClip(&c1, cap: AppSettings.shared.maxHistoryItems)
        var c2 = makeTextClip(multiline); try source.saveCapturedClip(&c2, cap: AppSettings.shared.maxHistoryItems)
        let id1 = try XCTUnwrap(source.allClips().first { $0.contentText == "swift build" }?.id)
        let id2 = try XCTUnwrap(source.allClips().first { $0.contentText == multiline }?.id)
        try source.setClip(id1, inCategory: workID, true)
        try source.setClip(id2, inCategory: workID, true)
        try source.updateClipTitle(id: id1, userTitle: "Build")

        let toml = try ClippyArchive.exportTOML(from: source)
        print("----- clippy.toml -----\n\(toml)\n-----------------------")

        XCTAssertTrue(toml.contains("schema_version = 1"))
        XCTAssertTrue(toml.contains("[[category]]"))
        XCTAssertTrue(toml.contains("swift build"))

        // Import into a fresh database.
        let dest = try makeTestDatabase(self)
        let summary = try ClippyArchive.importTOML(toml, into: dest)
        XCTAssertGreaterThanOrEqual(summary.categories, 2)  // Pinned + Work
        XCTAssertEqual(summary.clips, 2)

        let destWork = try XCTUnwrap(dest.categories().first { $0.name == "Work" })
        let destWorkID = try XCTUnwrap(destWork.id)
        XCTAssertEqual(destWork.colorHex, "#007AFF")
        XCTAssertEqual(destWork.iconValue, "briefcase.fill")

        let map = try dest.membershipMap()
        let pinned = try dest.allClips()
            .filter { ($0.id.flatMap { map[$0] } ?? []).contains(destWorkID) }
            .map(\.contentText)
        XCTAssertEqual(Set(pinned), ["swift build", multiline])
        // The multi-line clip with an embedded quote must survive the round trip.
        XCTAssertTrue(try dest.allClips().contains { $0.contentText == multiline })

        let build = try XCTUnwrap(dest.allClips().first { $0.contentText == "swift build" })
        XCTAssertEqual(build.userTitle, "Build")
    }

    func testImportIsIdempotent() throws {
        let source = try makeTestDatabase(self)
        let notes = try source.createCategory(
            named: "Notes", colorHex: "#34C759", iconKind: .emoji, iconValue: "\u{1F4DD}"
        )
        let notesID = try XCTUnwrap(notes.id)
        var clip = makeTextClip("remember this"); try source.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let cid = try XCTUnwrap(source.allClips().first?.id)
        try source.setClip(cid, inCategory: notesID, true)
        let toml = try ClippyArchive.exportTOML(from: source)

        let dest = try makeTestDatabase(self)
        _ = try ClippyArchive.importTOML(toml, into: dest)
        _ = try ClippyArchive.importTOML(toml, into: dest)  // second import must not duplicate

        XCTAssertEqual(try dest.allClips().filter { $0.contentText == "remember this" }.count, 1)
        XCTAssertEqual(try dest.categories().filter { $0.name == "Notes" }.count, 1)
    }

    func testImportHandwrittenTOML() throws {
        // A user authoring the file from scratch must work, not just round-trips.
        let toml = """
        schema_version = 1
        exported_at = "2026-06-11T00:00:00Z"

        [[category]]
        name = "Snippets"
        color = "#FF2D55"
        icon_kind = "symbol"
        icon = "curlybraces"
        position = 5
        starter = false

          [[category.clip]]
          kind = "text"
          title = "Greeting"
          text = "hello world"
        """
        let dest = try makeTestDatabase(self)
        let summary = try ClippyArchive.importTOML(toml, into: dest)
        XCTAssertEqual(summary.categories, 1)
        XCTAssertEqual(summary.clips, 1)

        let category = try XCTUnwrap(dest.categories().first { $0.name == "Snippets" })
        XCTAssertEqual(category.sortOrder, 5)
        XCTAssertEqual(category.iconValue, "curlybraces")
        let clip = try XCTUnwrap(dest.allClips().first { $0.contentText == "hello world" })
        XCTAssertEqual(clip.userTitle, "Greeting")
    }

    func testIconKindTOMLMapping() {
        XCTAssertEqual(CategoryIconKind.appLogo.tomlValue, "app")
        XCTAssertEqual(CategoryIconKind.symbol.tomlValue, "symbol")
        XCTAssertEqual(CategoryIconKind.fromTOML("app"), .appLogo)
        XCTAssertEqual(CategoryIconKind.fromTOML("emoji"), .emoji)
        XCTAssertEqual(CategoryIconKind.fromTOML("anything"), .symbol)
    }

    // MARK: - quote() hostile-input round-trip tests

    /// Verifies that exportTOML -> importTOML preserves clip text byte-for-byte
    /// for every class of input that previously broke the hand-written TOML emitter.
    func testQuoteHostileInputRoundTrip() throws {
        let cases: [(label: String, text: String)] = [
            // Text ending in a double quote fuses with a closing """ delimiter.
            ("ends with double quote",        "He said \"hi\""),
            // Triple quotes inside the body terminate a multi-line string early.
            ("contains triple quotes",        "a \"\"\" b"),
            // Windows line endings: bare \r before \n must not become two newlines.
            ("windows line endings",          "line1\r\nline2"),
            // Tab and backslash (backslash must be doubled, tab escaped).
            ("tab and backslash",             "col1\tcol2\\path"),
            // Bell control character (0x07).
            ("bell control char",             "bell\u{07}end"),
            // NOTE: a literal NUL (0x00) is intentionally NOT tested here. quote()
            // escapes it correctly to , but SQLite TEXT columns truncate at
            // an embedded NUL, so the DB round-trip (not the TOML layer) cannot
            // preserve it. macOS pasteboard text never contains a NUL.
            // Emoji + genuine multi-line content.
            ("emoji multiline",               "😀 first\nsecond line\n"),
            // String that ends with a backslash.
            ("ends with backslash",           "ends with backslash\\"),
            // String whose body contains two consecutive double quotes (not three).
            ("two consecutive double quotes", "a \"\" b"),
            // All standard single-line escapes together.
            ("mixed escapes single line",     "tab:\t back:\\ cr:\r quote:\""),
        ]

        for (label, text) in cases {
            // Build a minimal archive with just a Pinned category and one clip.
            let db = try makeTestDatabase(self)
            var clip = makeTextClip(text)
            try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
            let clipID = try XCTUnwrap(
                db.allClips().first { $0.contentText == text }?.id,
                "Could not find saved clip for case: \(label)"
            )
            // Pin it into the default Pinned category.
            let pinned = try XCTUnwrap(db.categories().first, "No categories in DB for case: \(label)")
            let pinnedID = try XCTUnwrap(pinned.id)
            try db.setClip(clipID, inCategory: pinnedID, true)

            // Export.
            let toml = try ClippyArchive.exportTOML(from: db)

            // Import into a fresh DB.
            let dest = try makeTestDatabase(self)
            _ = try ClippyArchive.importTOML(toml, into: dest)

            // The exact text must survive the round trip.
            let recovered = try dest.allClips().compactMap { $0.contentText }
            XCTAssertTrue(
                recovered.contains(text),
                "Round-trip failed for case '\(label)'. TOML was:\n\(toml)"
            )
        }
    }

    /// Title strings go through quote() too; verify they round-trip as well.
    func testQuoteHostileInputInTitle() throws {
        // No literal NUL: SQLite TEXT truncates at NUL, so it cannot survive a DB
        // round-trip (a storage limit, not a TOML-serializer bug). quote() still
        // escapes NUL correctly at the TOML layer.
        let hostileTitle = "He said \"\"\" and \\ then\ttabbed\r\nand done"

        let db = try makeTestDatabase(self)
        var clip = makeTextClip("content")
        try db.saveCapturedClip(&clip, cap: AppSettings.shared.maxHistoryItems)
        let clipID = try XCTUnwrap(db.allClips().first?.id)
        let pinned = try XCTUnwrap(db.categories().first)
        let pinnedID = try XCTUnwrap(pinned.id)
        try db.setClip(clipID, inCategory: pinnedID, true)
        try db.updateClipTitle(id: clipID, userTitle: hostileTitle)

        let toml = try ClippyArchive.exportTOML(from: db)
        let dest = try makeTestDatabase(self)
        _ = try ClippyArchive.importTOML(toml, into: dest)

        let recovered = try XCTUnwrap(dest.allClips().first { $0.contentText == "content" })
        XCTAssertEqual(recovered.userTitle, hostileTitle)
    }
}
