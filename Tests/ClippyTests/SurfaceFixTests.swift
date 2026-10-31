import XCTest
@testable import Clippy

final class SurfaceFixTests: XCTestCase {
    // MARK: Card appearance (finding 2)

    func testFilledAndBorderedDifferInFaceAndEdge() {
        let filled = CardAppearance.resolve(style: .filled, colorMode: .neutral, tintStrength: 8, highContrast: false)
        let bordered = CardAppearance.resolve(style: .bordered, colorMode: .neutral, tintStrength: 8, highContrast: false)
        XCTAssertEqual(filled.face, .solid)
        XCTAssertEqual(filled.edge, .hairline)
        XCTAssertEqual(bordered.face, .clear)
        XCTAssertEqual(bordered.edge, .strong)
    }

    func testPlainHasNoChromeAndNoTint() {
        let plain = CardAppearance.resolve(style: .plain, colorMode: .byApp, tintStrength: 20, highContrast: false)
        XCTAssertEqual(plain.edge, .none)
        XCTAssertEqual(plain.tint, .none)
        XCTAssertEqual(plain.tintOpacity, 0)
    }

    func testColorModeSelectsTintSource() {
        func tint(_ mode: CardColorMode) -> CardAppearance.Tint {
            CardAppearance.resolve(style: .filled, colorMode: mode, tintStrength: 10, highContrast: false).tint
        }
        XCTAssertEqual(tint(.byApp), .sourceApp)
        XCTAssertEqual(tint(.byKind), .kind)
        XCTAssertEqual(tint(.accent), .accent)
        XCTAssertEqual(tint(.neutral), .none)
    }

    func testTintStrengthIsPercentAndClamped() {
        func opacity(_ strength: Int) -> Double {
            CardAppearance.resolve(style: .filled, colorMode: .accent, tintStrength: strength, highContrast: false).tintOpacity
        }
        XCTAssertEqual(opacity(8), 0.08, accuracy: 1e-9)
        XCTAssertEqual(opacity(500), 0.20, accuracy: 1e-9)
        XCTAssertEqual(opacity(-3), 0)
        XCTAssertEqual(CardAppearance.resolve(style: .filled, colorMode: .accent, tintStrength: 0, highContrast: false).tint, .none)
    }

    func testHighContrastFlagReachesAppearance() {
        XCTAssertTrue(CardAppearance.resolve(style: .filled, colorMode: .neutral, tintStrength: 8, highContrast: true).usesPrimaryForSecondaryText)
        XCTAssertFalse(CardAppearance.resolve(style: .filled, colorMode: .neutral, tintStrength: 8, highContrast: false).usesPrimaryForSecondaryText)
    }

    // MARK: Accent swatch check (finding 8)

    func testSwatchMarkIsDarkOnLightFillAndLightOnDarkFill() {
        XCTAssertEqual(AccentSwatchContrast.markColor(on: RGBA(red: 1.0, green: 0.8, blue: 0.0)), .black)
        XCTAssertEqual(AccentSwatchContrast.markColor(on: RGBA(red: 0xE0 / 255.0, green: 0xA2 / 255.0, blue: 0x3C / 255.0)), .black)
        XCTAssertEqual(AccentSwatchContrast.markColor(on: RGBA(red: 0.0, green: 0.3, blue: 0.8)), .white)
    }

    // MARK: Zip extraction (finding 5)

    func testUniqueDirectoryAppendsCounterWhenTaken() {
        let parent = URL(fileURLWithPath: "/Downloads")
        var taken: Set<String> = []
        func pick() -> String {
            let url = ZipExtractNaming.uniqueDirectory(baseName: "report", in: parent) { taken.contains($0.lastPathComponent) }
            taken.insert(url.lastPathComponent)
            return url.lastPathComponent
        }
        XCTAssertEqual(pick(), "report")
        XCTAssertEqual(pick(), "report 2")
        XCTAssertEqual(pick(), "report 3")
    }

    func testUniqueDirectoryHandlesEmptyBaseAndFailureWording() {
        let parent = URL(fileURLWithPath: "/Downloads")
        XCTAssertEqual(ZipExtractNaming.uniqueDirectory(baseName: "", in: parent) { _ in false }.lastPathComponent, "Extracted")
        XCTAssertTrue(ZipExtractNaming.failureDetail(reason: "").hasSuffix("password protected."))
        XCTAssertTrue(ZipExtractNaming.failureDetail(reason: "bad CRC").hasSuffix("(bad CRC)"))
    }

    // MARK: Copy (findings 6, 10, 15)

    func testClickCopyOnlyTitleDoesNotClaimSingleClick() {
        let entry = SettingsSearchCatalog.entries.first { $0.id == "general.clickCopyOnly" }
        XCTAssertEqual(entry?.title, SettingsCopy.clickCopyOnlyTitle)
        XCTAssertFalse(SettingsCopy.clickCopyOnlyTitle.lowercased().hasPrefix("clicking"))
    }

    func testConflictMessageNamesTheBannerButtons() {
        XCTAssertTrue(EditorConflictCopy.resolveFirst.contains(EditorConflictCopy.useStored))
        XCTAssertTrue(EditorConflictCopy.resolveFirst.contains(EditorConflictCopy.keepMine))
        XCTAssertFalse(EditorConflictCopy.resolveFirst.contains("Reload"))
    }

    func testCountCopySingularAndPlural() {
        XCTAssertEqual(CountCopy.tamperingNotFound(entries: 1, files: 1), "No tampering found in 1 entry across 1 file.")
        XCTAssertEqual(CountCopy.tamperingNotFound(entries: 2, files: 3), "No tampering found in 2 entries across 3 files.")
        XCTAssertEqual(CountCopy.exportedEntries(1), "Exported 1 entry.")
        XCTAssertEqual(CountCopy.exportedEntries(0), "Exported 0 entries.")
        XCTAssertEqual(CountCopy.skippedImages(1), "Skipped 1 image whose file was missing.")
        XCTAssertEqual(CountCopy.skippedImages(2), "Skipped 2 images whose files were missing.")
        XCTAssertEqual(CountCopy.importedSettings(1, from: "a.json"), "Imported 1 setting from a.json.")
        XCTAssertEqual(CountCopy.sectionLabel(title: "Categories", count: 1), "Categories, 1 item")
        XCTAssertEqual(CountCopy.sectionLabel(title: "Categories", count: nil), "Categories")
        XCTAssertEqual(CountCopy.listSummary(1), "1 item")
    }

    // MARK: Category editor swatches (finding 11)

    func testSwatchRowsFitAndBalance() {
        let columns = SwatchRowLayout.columns(available: 252, itemWidth: 20, spacing: 8, itemCount: 10)
        XCTAssertEqual(columns, 5)
        XCTAssertLessThanOrEqual(CGFloat(columns) * 20 + CGFloat(columns - 1) * 8, 252)
        XCTAssertEqual(SwatchRowLayout.columns(available: 252, itemWidth: 20, spacing: 8, itemCount: 4), 4)
        XCTAssertEqual(SwatchRowLayout.columns(available: 10, itemWidth: 20, spacing: 8, itemCount: 3), 1)
    }

    // MARK: Search anchors (finding 12)

    /// Every dotted catalog id must be declared by a `.settingsRow("id")` call or a
    /// `SettingsAdvanced(anchors: [...])` list, or the search jump has nothing to scroll to.
    func testEveryCatalogRowHasAnAnchor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Clippy")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("sources not reachable from the test bundle")
        }
        var declared = Set<String>()
        let single = try NSRegularExpression(pattern: "settingsRow\\(\"([^\"]+)\"\\)")
        let list = try NSRegularExpression(pattern: "anchors:\\s*\\[([^\\]]*)\\]")
        let quoted = try NSRegularExpression(pattern: "\"([^\"]+)\"")
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            for match in single.matches(in: text, range: whole) {
                declared.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
            for match in list.matches(in: text, range: whole) {
                let body = String(text[Range(match.range(at: 1), in: text)!])
                for item in quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    declared.insert(String(body[Range(item.range(at: 1), in: body)!]))
                }
            }
        }
        if declared.isEmpty { throw XCTSkip("no anchors found; source tree not available") }
        let missing = SettingsSearchCatalog.entries.map(\.id).filter { $0.contains(".") && !declared.contains($0) }
        XCTAssertEqual(missing, [], "catalog rows without a .settingsRow anchor")
    }

    // MARK: Pane reset refresh (finding 4)

    func testCapturePolicySnapshotReadsStorageAfterReset() {
        let suite = "SurfaceFixTests.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suite)!
        let previous = CapturePreferences.defaults
        CapturePreferences.defaults = scratch
        defer {
            CapturePreferences.defaults = previous
            scratch.removePersistentDomain(forName: suite)
        }
        CapturePreferences.typeBlocklist = ["com.example.secret"]
        CapturePreferences.captureOnLaunch = true
        XCTAssertEqual(CapturePolicySnapshot.load().blocklist, ["com.example.secret"])
        // What a pane reset does: remove the keys from storage.
        scratch.removeObject(forKey: CapturePreferences.Key.typeBlocklist)
        scratch.removeObject(forKey: CapturePreferences.Key.captureOnLaunch)
        let after = CapturePolicySnapshot.load()
        XCTAssertEqual(after.blocklist, [])
        XCTAssertFalse(after.captureOnLaunch)
    }
}
