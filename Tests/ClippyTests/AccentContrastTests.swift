import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Accent-filled buttons draw `tokens.onAccent` on `tokens.accent` (see `AccentButtonStyle`).
/// Seeded fault: a label that is always white fails `testDefaultGoldAccentGetsDarkLabel`
/// (white on #E0A23C is about 2.2:1).
final class AccentContrastTests: XCTestCase {
    private func resolved(accent: Color, base: ThemeTokens = ThemePreset.cleanLight.fixedTokens!, dark: Bool = false) -> ClippyTokens {
        var tokens = base
        tokens.isDark = dark
        tokens.accent = accent
        return ClippyTokens.resolve(from: tokens)
    }

    private func labelRatio(_ tokens: ClippyTokens) -> Double {
        let dark = tokens.scheme == .dark
        let label = RGBA(color: tokens.onAccent, isDark: dark)!
        let fill = RGBA(color: tokens.accent, isDark: dark)!
        return ContrastAudit.ratio(label, on: fill)
    }

    private func isDarkLabel(_ tokens: ClippyTokens) -> Bool {
        RGBA(color: tokens.onAccent, isDark: tokens.scheme == .dark)!.luminance < 0.5
    }

    /// Every preset, in both appearances, with its own accent.
    func testOnAccentMeetsAAForEveryPreset() {
        for preset in ThemePreset.selectable {
            let source = preset.fixedTokens ?? Theme.customSeed
            for dark in [false, true] {
                var tokens = source
                tokens.isDark = dark
                let semantic = ClippyTokens.resolve(from: tokens)
                XCTAssertGreaterThanOrEqual(labelRatio(semantic), 4.5, "\(preset.rawValue) \(dark ? "dark" : "light")")
            }
        }
    }

    /// Every accent the picker offers, over a light and a dark base.
    func testOnAccentMeetsAAForEveryAccentTheme() {
        for accent in AccentTheme.allCases {
            for dark in [false, true] {
                let base = (dark ? ThemePreset.githubDark : ThemePreset.cleanLight).fixedTokens!
                let tokens = resolved(accent: accent.color, base: base, dark: dark)
                XCTAssertGreaterThanOrEqual(labelRatio(tokens), 4.5, "\(accent.rawValue) \(dark ? "dark" : "light")")
            }
        }
    }

    /// `accentInk` is the window tint, so tinted/bordered text buttons draw it on every surface.
    /// Seeded fault: returning the raw accent fails here (gold #E0A23C on a light surface is about 2.2:1).
    func testAccentInkMeetsAAOnEverySurfaceForEveryPresetAndAccent() {
        func check(_ tokens: ClippyTokens, _ name: String) {
            let dark = tokens.scheme == .dark
            let ink = RGBA(color: tokens.accentInk, isDark: dark)!
            let surfaces = [("surface", tokens.surface), ("surfaceElevated", tokens.surfaceElevated),
                            ("surfaceInset", tokens.surfaceInset), ("surfaceSidebar", tokens.surfaceSidebar)]
            for (surfaceName, surface) in surfaces {
                let ratio = ContrastAudit.ratio(ink, on: RGBA(color: surface, isDark: dark)!)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) \(dark ? "dark" : "light") accentInk on \(surfaceName)")
            }
        }
        for preset in ThemePreset.selectable {
            let source = preset.fixedTokens ?? Theme.customSeed
            for dark in [false, true] {
                var tokens = source
                tokens.isDark = dark
                check(ClippyTokens.resolve(from: tokens), preset.rawValue)
            }
        }
        for accent in AccentTheme.allCases {
            for dark in [false, true] {
                let base = (dark ? ThemePreset.githubDark : ThemePreset.cleanLight).fixedTokens!
                check(resolved(accent: accent.color, base: base, dark: dark), accent.rawValue)
            }
        }
    }

    func testDefaultGoldAccentGetsDarkLabel() {
        let tokens = resolved(accent: AccentTheme.clippyAmber.color)
        XCTAssertTrue(isDarkLabel(tokens), "gold accent must not get a white label")
        XCTAssertGreaterThanOrEqual(labelRatio(tokens), 4.5)
    }

    /// White on #007AFF is only about 3.8:1, so AA requires the dark label there.
    func testSystemBlueLabelPassesAA() {
        let tokens = resolved(accent: Color(themeHex: "#007AFF"))
        XCTAssertGreaterThanOrEqual(labelRatio(tokens), 4.5)
    }

    func testDeepBlueAccentGetsWhiteLabel() {
        let tokens = resolved(accent: Color(themeHex: "#0B57D0"))
        XCTAssertFalse(isDarkLabel(tokens))
        XCTAssertGreaterThanOrEqual(labelRatio(tokens), 4.5)
    }

    @MainActor
    func testCustomAccentOverrideGetsPassingLabel() {
        let settings = AppSettings.shared
        let savedPreset = settings.themePreset
        let savedAccentTheme = settings.accentTheme
        let savedAccent = settings.customAccentHex
        defer {
            settings.themePreset = savedPreset
            settings.accentTheme = savedAccentTheme
            settings.customAccentHex = savedAccent
        }
        settings.themePreset = .cleanLight
        for hex in ["#E0A23C", "#0B57D0", "#7F7F7F", "#FFFFFF", "#000000"] {
            settings.customAccentHex = hex
            let tokens = ClippyTokens.resolve(from: Theme.tokens(settings))
            XCTAssertGreaterThanOrEqual(labelRatio(tokens), 4.5, hex)
        }
    }
}
