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
        let tokens = ThemePreset.tokyoNight.fixedTokens!
        XCTAssertEqual(tokens.panel.themeHexString, "#1A1B26")
        XCTAssertEqual(tokens.scrollBackground.themeHexString, "#16161E")
        XCTAssertEqual(tokens.cardSurface.themeHexString, "#24283B")
        XCTAssertEqual(tokens.cardBorder.themeHexString, "#292E42")
        XCTAssertEqual(tokens.headerBar.themeHexString, "#16161E")
        XCTAssertEqual(tokens.footerBar.themeHexString, "#16161E")
        XCTAssertEqual(tokens.sidebar.themeHexString, "#16161E")
        XCTAssertEqual(tokens.scrollbar.themeHexString, "#414868")
        XCTAssertEqual(tokens.textPrimary.themeHexString, "#C0CAF5")
        XCTAssertEqual(tokens.textSecondary.themeHexString, "#A9B1D6")
        XCTAssertEqual(tokens.accent.themeHexString, "#7AA2F7")
        XCTAssertEqual(tokens.success.themeHexString, "#9ECE6A")
        XCTAssertEqual(tokens.danger.themeHexString, "#F7768E")
        XCTAssertTrue(tokens.isDark)
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
        let settings = AppSettings.shared
        let savedPreset = settings.themePreset
        let savedPanel = settings.customPanelHex
        defer { settings.themePreset = savedPreset; settings.customPanelHex = savedPanel }

        settings.themePreset = .nord
        settings.customPanelHex = "#123456"
        XCTAssertEqual(Theme.tokens(settings).panel.themeHexString, "#123456")
    }

    func testEmptyOverrideFallsBackToPresetBase() {
        let settings = AppSettings.shared
        let savedPreset = settings.themePreset
        let savedPanel = settings.customPanelHex
        defer { settings.themePreset = savedPreset; settings.customPanelHex = savedPanel }

        settings.themePreset = .nord
        settings.customPanelHex = ""
        XCTAssertEqual(Theme.tokens(settings).panel.themeHexString,
                       ThemePreset.nord.fixedTokens!.panel.themeHexString)
    }

    func testAccentOverrideWinsOverAccentTheme() {
        let settings = AppSettings.shared
        let savedPreset = settings.themePreset
        let savedAccentTheme = settings.accentTheme
        let savedAccent = settings.customAccentHex
        defer {
            settings.themePreset = savedPreset
            settings.accentTheme = savedAccentTheme
            settings.customAccentHex = savedAccent
        }

        settings.themePreset = .githubDark
        settings.accentTheme = .clippyAmber  // non-system accent applies under the override
        settings.customAccentHex = "#ABCDEF"
        XCTAssertEqual(Theme.tokens(settings).accent.themeHexString, "#ABCDEF")
    }

    func testSuccessAndDangerAreOverridable() {
        let settings = AppSettings.shared
        let savedPreset = settings.themePreset
        let savedSuccess = settings.customSuccessHex
        let savedDanger = settings.customDangerHex
        defer {
            settings.themePreset = savedPreset
            settings.customSuccessHex = savedSuccess
            settings.customDangerHex = savedDanger
        }

        settings.themePreset = .nord
        settings.customSuccessHex = "#00FF00"
        settings.customDangerHex = "#FF0000"
        let tokens = Theme.tokens(settings)
        XCTAssertEqual(tokens.success.themeHexString, "#00FF00")
        XCTAssertEqual(tokens.danger.themeHexString, "#FF0000")
    }
}
