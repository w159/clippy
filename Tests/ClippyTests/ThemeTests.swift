import XCTest
import AppKit
@testable import Clippy

@MainActor
final class ThemeTests: XCTestCase {

    // MARK: - Hex round-trip

    func testHexRoundTrip() {
        for hex in ["#0D1117", "#FFFFFF", "#1F2328", "#03DAC6", "#BD93F9"] {
            let color = NSColor(themeHex: hex)
            XCTAssertNotNil(color, "\(hex) should parse")
            XCTAssertEqual(color?.themeHexString, hex, "\(hex) should round-trip")
        }
    }

    func testShortHexParses() {
        XCTAssertNotNil(NSColor(themeHex: "#0F0"))
        XCTAssertNotNil(NSColor(themeHex: "0F0"))  // leading # optional
    }

    func testEightDigitHexParsesAlpha() {
        XCTAssertNotNil(NSColor(themeHex: "#11223344"))
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(NSColor(themeHex: "nothex"))
        XCTAssertNil(NSColor(themeHex: "#12"))
    }

    // MARK: - Preset token tables

    func testNamedPresetsHaveFixedTokens() {
        let named: [ThemePreset] = [.cleanLight, .githubDark, .dracula, .materialDarkPlus, .nord, .oneDark, .solarizedDark]
        for preset in named {
            XCTAssertNotNil(preset.fixedTokens, "\(preset.label) must define a token table")
        }
    }

    func testDynamicPresetsHaveNoFixedTokens() {
        XCTAssertNil(ThemePreset.system.fixedTokens)
        XCTAssertNil(ThemePreset.custom.fixedTokens)
    }

    func testDarkPresetsMarkedDark() {
        XCTAssertTrue(ThemePreset.githubDark.fixedTokens!.isDark)
        XCTAssertTrue(ThemePreset.dracula.fixedTokens!.isDark)
        XCTAssertFalse(ThemePreset.cleanLight.fixedTokens!.isDark)
    }

    func testCustomSeedIsCleanLight() {
        XCTAssertEqual(Theme.customSeed.panel.themeHexString, "#FFFFFF")
        XCTAssertEqual(Theme.customSeed.accent.themeHexString, "#0969DA")
    }

    func testSelectableIncludesSystemAndCustom() {
        XCTAssertTrue(ThemePreset.selectable.contains(.system))
        XCTAssertTrue(ThemePreset.selectable.contains(.custom))
        XCTAssertEqual(ThemePreset.selectable.count, ThemePreset.allCases.count)
    }

    // MARK: - Authoritative palette hex (round-trip against canonical sources)

    func testNordPanelIsPolarNightNotOldValue() {
        // Source: nordtheme.com. nord0 #2E3440; the old #272B35 was never Nord.
        let nord = ThemePreset.nord.fixedTokens!
        XCTAssertEqual(nord.panel.themeHexString, "#2E3440")
        XCTAssertEqual(nord.scrollBackground.themeHexString, "#2E3440")
        XCTAssertEqual(nord.cardBorder.themeHexString, "#434C5E")
        XCTAssertEqual(nord.textSecondary.themeHexString, "#D8DEE9")
    }

    func testTokyoNightHasCanonicalHex() {
        // Source: github.com/enkia/tokyo-night-vscode-theme (Night variant).
        let t = ThemePreset.tokyoNight.fixedTokens!
        XCTAssertEqual(t.panel.themeHexString, "#1A1B26")
        XCTAssertEqual(t.scrollBackground.themeHexString, "#16161E")
        XCTAssertEqual(t.cardSurface.themeHexString, "#24283B")
        XCTAssertEqual(t.cardBorder.themeHexString, "#292E42")
        XCTAssertEqual(t.headerBar.themeHexString, "#16161E")
        XCTAssertEqual(t.footerBar.themeHexString, "#16161E")
        XCTAssertEqual(t.sidebar.themeHexString, "#16161E")
        XCTAssertEqual(t.scrollbar.themeHexString, "#414868")
        XCTAssertEqual(t.textPrimary.themeHexString, "#C0CAF5")
        XCTAssertEqual(t.textSecondary.themeHexString, "#A9B1D6")
        XCTAssertEqual(t.accent.themeHexString, "#7AA2F7")
        XCTAssertEqual(t.success.themeHexString, "#9ECE6A")
        XCTAssertEqual(t.danger.themeHexString, "#F7768E")
        XCTAssertTrue(t.isDark)
    }

    func testTokyoNightIsSelectableAfterOneDark() {
        let selectable = ThemePreset.selectable
        let oneDarkIdx = selectable.firstIndex(of: .oneDark)!
        XCTAssertEqual(selectable[oneDarkIdx + 1], .tokyoNight)
    }

    // MARK: - Per-token override overlay
    //
    // These mutate the shared AppSettings (tests use .shared, matching the
    // existing seam). They save and restore the touched override so they do not
    // leak state into other tests.

    func testOverrideReplacesPanelOnNamedPreset() {
        let s = AppSettings.shared
        let savedPreset = s.themePreset
        let savedPanel = s.customPanelHex
        defer { s.themePreset = savedPreset; s.customPanelHex = savedPanel }

        s.themePreset = .nord
        s.customPanelHex = "#123456"
        XCTAssertEqual(Theme.tokens(s).panel.themeHexString, "#123456")
    }

    func testEmptyOverrideFallsBackToPresetBase() {
        let s = AppSettings.shared
        let savedPreset = s.themePreset
        let savedPanel = s.customPanelHex
        defer { s.themePreset = savedPreset; s.customPanelHex = savedPanel }

        s.themePreset = .nord
        s.customPanelHex = ""
        XCTAssertEqual(Theme.tokens(s).panel.themeHexString,
                       ThemePreset.nord.fixedTokens!.panel.themeHexString)
    }

    func testAccentOverrideWinsOverAccentTheme() {
        let s = AppSettings.shared
        let savedPreset = s.themePreset
        let savedAccentTheme = s.accentTheme
        let savedAccent = s.customAccentHex
        defer {
            s.themePreset = savedPreset
            s.accentTheme = savedAccentTheme
            s.customAccentHex = savedAccent
        }

        s.themePreset = .githubDark
        s.accentTheme = .clippyAmber  // non-system accent applies under the override
        s.customAccentHex = "#ABCDEF"
        XCTAssertEqual(Theme.tokens(s).accent.themeHexString, "#ABCDEF")
    }

    func testSuccessAndDangerAreOverridable() {
        let s = AppSettings.shared
        let savedPreset = s.themePreset
        let savedSuccess = s.customSuccessHex
        let savedDanger = s.customDangerHex
        defer {
            s.themePreset = savedPreset
            s.customSuccessHex = savedSuccess
            s.customDangerHex = savedDanger
        }

        s.themePreset = .nord
        s.customSuccessHex = "#00FF00"
        s.customDangerHex = "#FF0000"
        let t = Theme.tokens(s)
        XCTAssertEqual(t.success.themeHexString, "#00FF00")
        XCTAssertEqual(t.danger.themeHexString, "#FF0000")
    }
}
