import AppKit
import SwiftUI
import XCTest
@testable import Clippy

final class DesignSystemTests: XCTestCase {
    /// Every persisted preset is audited in both effective appearance modes.
    func testEveryPresetPassesSemanticTextAndNonTextContrast() {
        for preset in ThemePreset.allCases {
            let source = preset.fixedTokens ?? Theme.customSeed
            for dark in [false, true] {
                var tokens = source
                tokens.isDark = dark
                let semantic = ClippyTokens.resolve(from: tokens)
                let failures = ContrastAudit.audit(semantic).filter { !$0.passes }
                XCTAssertTrue(failures.isEmpty, "\(preset.rawValue) \(dark ? "dark" : "light"): \(failures)")
            }
        }
    }

    /// Every semantic token keeps the legacy source palette and maps the four
    /// legacy text/surface roles directly; contrast companions live separately.
    func testSemanticBridgePreservesLegacyValuesForEveryPreset() {
        for preset in ThemePreset.allCases {
            let source = preset.fixedTokens ?? Theme.customSeed
            for dark in [false, true] {
                var original = source
                original.isDark = dark
                let resolved = ClippyTokens.resolve(from: original)
                XCTAssertEqual(resolved.legacy.isDark, original.isDark, preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.panel, dark), rgb(original.panel, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.scrollBackground, dark), rgb(original.scrollBackground, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.cardSurface, dark), rgb(original.cardSurface, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.cardBorder, dark), rgb(original.cardBorder, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.headerBar, dark), rgb(original.headerBar, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.footerBar, dark), rgb(original.footerBar, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.sidebar, dark), rgb(original.sidebar, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.scrollbar, dark), rgb(original.scrollbar, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.textPrimary, dark), rgb(original.textPrimary, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.textSecondary, dark), rgb(original.textSecondary, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.accent, dark), rgb(original.accent, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.success, dark), rgb(original.success, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.legacy.danger, dark), rgb(original.danger, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.surface, dark), rgb(original.scrollBackground, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.surfaceElevated, dark), rgb(original.cardSurface, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.surfaceInset, dark), rgb(original.headerBar, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.surfaceSidebar, dark), rgb(original.sidebar, dark), preset.rawValue)
                XCTAssertEqual(rgb(resolved.accent, dark), rgb(original.accent, dark), preset.rawValue)
            }
        }
    }

    /// Increase Contrast strengthens generated text, stroke and icon roles while
    /// Reduce Motion selects the documented opacity-only fallback and duration.
    func testMotionFallbackSelectionAndDurations() {
        let motion = MotionSpec()
        XCTAssertEqual(motion.behavior(reduceMotion: false), .fullMotion)
        XCTAssertEqual(motion.behavior(reduceMotion: true), .opacityOnly)
        XCTAssertEqual(motion.duration(for: .standard, reduceMotion: false), 0.22, accuracy: 0.001)
        XCTAssertEqual(motion.duration(for: .standard, reduceMotion: true), 0.08, accuracy: 0.001)
        XCTAssertEqual(motion.duration(for: .toastIn, reduceMotion: true), 0.15, accuracy: 0.001)
        XCTAssertEqual(motion.duration(for: .toastIn, reduceMotion: false), 0.15, accuracy: 0.001)
        XCTAssertEqual(motion.duration(for: .toastOut, reduceMotion: false), 0.18, accuracy: 0.001)
    }

    /// Pure presentation rules guarantee sensitive content is replaced by a
    /// fixed, safe placeholder and only appears while explicit reveal is held.
    func testMaskedTextLogicNeverPartiallyExposesSensitiveContent() {
        let sensitive = "Client account 1042"
        XCTAssertFalse(MaskedTextLogic.isVisible(sensitive: true, revealHeld: false))
        XCTAssertEqual(MaskedTextLogic.displayedText(sensitive, sensitive: true, revealHeld: false), "Sensitive content")
        XCTAssertTrue(MaskedTextLogic.isVisible(sensitive: true, revealHeld: true))
        XCTAssertEqual(MaskedTextLogic.displayedText(sensitive, sensitive: true, revealHeld: true), sensitive)
        XCTAssertTrue(MaskedTextLogic.isVisible(sensitive: false, revealHeld: false))
        XCTAssertEqual(MaskedTextLogic.displayedText(sensitive, sensitive: false, revealHeld: false), sensitive)
    }

    /// Text multiplier is range-checked before persistence and malformed values
    /// cannot leak into font computations.
    func testTextScaleValidation() {
        XCTAssertTrue(ClippyTextScale.setMultiplier(1.25))
        XCTAssertEqual(ClippyTextScale.multiplier, 1.25)
        XCTAssertFalse(ClippyTextScale.setMultiplier(0.5))
        XCTAssertFalse(ClippyTextScale.setMultiplier(.infinity))
        UserDefaults.standard.removeObject(forKey: ClippyTextScale.userDefaultsKey)
        XCTAssertEqual(ClippyTextScale.multiplier, 1)
    }

    private func rgb(_ color: Color, _ dark: Bool) -> RGBA? { RGBA(color: color, isDark: dark) }
}
