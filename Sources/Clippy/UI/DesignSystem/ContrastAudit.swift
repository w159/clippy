import AppKit
import SwiftUI

// Pure WCAG 2.x contrast math (SET-01). No SwiftUI state, no settings: given
// colors in, ratios out, so the audit is unit-testable for every preset and the
// token derivation can push a color toward black/white until it passes.

// MARK: - RGBA

/// A resolved sRGB color, components 0...1. Alpha is kept so translucent system
/// label colors can be composited over the surface they are drawn on before
/// their luminance is measured.
struct RGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let white = RGBA(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` or `#RGB`; nil when unparseable.
    init?(hex: String) {
        guard let nsColor = NSColor(themeHex: hex), let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent))
    }

    /// Resolves a SwiftUI/AppKit (possibly dynamic) color under the light or
    /// dark aqua appearance. nil if the color has no sRGB representation.
    init?(color: Color, isDark: Bool) {
        var resolved: RGBA?
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            guard let drawn = NSColor(color).usingColorSpace(.sRGB) else { return }
            resolved = RGBA(red: Double(drawn.redComponent), green: Double(drawn.greenComponent), blue: Double(drawn.blueComponent), alpha: Double(drawn.alphaComponent))
        }
        guard let value = resolved else { return nil }
        self = value
    }

    /// This color drawn over an opaque background.
    func over(_ background: RGBA) -> RGBA {
        guard alpha < 1 else { return self }
        return RGBA(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    /// Linear interpolation toward `other` by `t` (0 = self, 1 = other), alpha ignored.
    func mixed(with other: RGBA, _ amount: Double) -> RGBA {
        let ratio = min(max(amount, 0), 1)
        return RGBA(red: red + (other.red - red) * ratio, green: green + (other.green - green) * ratio, blue: blue + (other.blue - blue) * ratio, alpha: alpha)
    }

    /// WCAG relative luminance of the opaque color.
    var luminance: Double {
        func lin(_ component: Double) -> Double { component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// `#RRGGBB` (alpha dropped).
    var hexString: String {
        func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

// MARK: - Audit

/// WCAG thresholds and helpers.
enum ContrastAudit {
    /// AA for normal text.
    static let textMinimum = 4.5
    /// AA for large text and meaningful non-text UI (strokes, icons, focus ring).
    static let nonTextMinimum = 3.0
    /// AAA for normal text; the target under Increase Contrast.
    static let enhancedText = 7.0

    /// Contrast ratio (1...21) of `foreground` drawn over `background`.
    static func ratio(_ foreground: RGBA, on background: RGBA) -> Double {
        let backdrop = background.over(.white)
        let fgLuminance = foreground.over(backdrop).luminance
        let bgL = backdrop.luminance
        let (lighter, darker) = fgLuminance >= bgL ? (fgLuminance, bgL) : (bgL, fgLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Smallest ratio of `foreground` across all `backgrounds`.
    static func worstRatio(_ foreground: RGBA, on backgrounds: [RGBA]) -> Double {
        backgrounds.map { ratio(foreground, on: $0) }.min() ?? 21
    }

    /// Returns `foreground` unchanged when it already meets `minimum` on every
    /// background; otherwise the closest color on the line from `foreground`
    /// toward black (light surfaces) or white (dark surfaces) that does. If even
    /// the pure endpoint fails, the endpoint is returned. Deterministic.
    static func adjust(_ foreground: RGBA, against backgrounds: [RGBA], minimum: Double) -> RGBA {
        guard !backgrounds.isEmpty else { return foreground }
        let base = foreground.over(backgrounds[0])
        if worstRatio(base, on: backgrounds) >= minimum { return foreground.alpha < 1 ? base : foreground }
        let meanLuminance = backgrounds.map(\.luminance).reduce(0, +) / Double(backgrounds.count)
        let target: RGBA = meanLuminance > 0.4 ? .black : .white
        if worstRatio(target, on: backgrounds) < minimum { return target }
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if worstRatio(base.mixed(with: target, mid), on: backgrounds) >= minimum + searchMargin { high = mid } else { low = mid }
        }
        return base.mixed(with: target, high)
    }

    /// Headroom the bisection keeps above `minimum` so Float32 color storage and
    /// sRGB round-trips can never land a hair (e.g. 4.4999997) under the threshold.
    private static let searchMargin = 0.005

    /// One measured foreground/background pair.
    struct Finding: Equatable {
        let role: String
        let background: String
        let ratio: Double
        let minimum: Double
        var passes: Bool { ratio >= minimum }
    }

    /// Text roles of a persisted `ThemeTokens` table against its own surfaces
    /// (the palette every preset ships). Alpha foregrounds are composited over
    /// each surface.
    static func audit(_ tokens: ThemeTokens) -> [Finding] {
        let dark = tokens.isDark
        let surfaces: [(String, Color)] = [
            ("panel", tokens.panel), ("scrollBackground", tokens.scrollBackground), ("cardSurface", tokens.cardSurface),
            ("headerBar", tokens.headerBar), ("footerBar", tokens.footerBar), ("sidebar", tokens.sidebar),
        ]
        let texts: [(String, Color)] = [("textPrimary", tokens.textPrimary), ("textSecondary", tokens.textSecondary)]
        var out: [Finding] = []
        for (role, fgSwatch) in texts {
            guard let fgColor = RGBA(color: fgSwatch, isDark: dark) else { continue }
            for (name, bgSwatch) in surfaces {
                guard let bgColor = RGBA(color: bgSwatch, isDark: dark) else { continue }
                out.append(Finding(role: role, background: name, ratio: ratio(fgColor, on: bgColor), minimum: textMinimum))
            }
        }
        return out
    }

    /// Text (4.5:1) and stroke/icon (3:1) roles of the derived semantic tokens
    /// on every surface they are drawn on. Audited pairs (each co-occurs in the UI):
    ///   - textPrimary, textSecondary, textTertiary, accentText (4.5:1) on
    ///     surface, surfaceElevated, surfaceInset, surfaceSidebar AND selection
    ///     (selected rows carry body text).
    ///   - success, warning, danger (4.5:1) on the four base surfaces only; status
    ///     colors are never drawn on the selection fill.
    ///   - stroke, strokeStrong, focusRing, scrollbar (3:1) on the four base surfaces.
    ///   - kind.* hues (3:1) on the four base surfaces (icon/stripe on the card),
    ///     not on selection.
    ///   - onAccent on accent (4.5:1).
    static func audit(_ tokens: ClippyTokens) -> [Finding] {
        let dark = tokens.scheme == .dark
        func rgba(_ swatch: Color) -> RGBA { RGBA(color: swatch, isDark: dark) ?? .black }
        let surfaces: [(String, Color)] = [
            ("surface", tokens.surface), ("surfaceElevated", tokens.surfaceElevated), ("surfaceInset", tokens.surfaceInset),
            ("surfaceSidebar", tokens.surfaceSidebar), ("selection", tokens.selection),
        ]
        let text: [(String, Color)] = [
            ("textPrimary", tokens.textPrimary), ("textSecondary", tokens.textSecondary), ("textTertiary", tokens.textTertiary),
            ("accentText", tokens.accentText),
        ]
        // status colors are never used for selected-row text (docs 01 section 6)
        let statusSurfaces = surfaces.filter { $0.0 != "selection" }
        let nonText: [(String, Color)] = [("stroke", tokens.stroke), ("strokeStrong", tokens.strokeStrong), ("focusRing", tokens.focusRing), ("scrollbar", tokens.scrollbar)]
        let base = tokens.strokeOnlySurfaces
        var out: [Finding] = []
        for (role, fgSwatch) in text {
            for (name, bgSwatch) in surfaces { out.append(Finding(role: role, background: name, ratio: ratio(rgba(fgSwatch), on: rgba(bgSwatch)), minimum: textMinimum)) }
        }
        for (role, fgSwatch) in [("success", tokens.success), ("warning", tokens.warning), ("danger", tokens.danger)] {
            for (name, bgSwatch) in statusSurfaces { out.append(Finding(role: role, background: name, ratio: ratio(rgba(fgSwatch), on: rgba(bgSwatch)), minimum: textMinimum)) }
        }
        for (role, fgSwatch) in nonText {
            for (name, bgSwatch) in surfaces where base.contains(name) { out.append(Finding(role: role, background: name, ratio: ratio(rgba(fgSwatch), on: rgba(bgSwatch)), minimum: nonTextMinimum)) }
        }
        // Kind hues are icons/stripes drawn on the card/list surfaces, never on the selection fill.
        for kind in ClipKindStyle.allCases {
            let foreground = tokens.kind(kind)
            for (name, background) in statusSurfaces {
                out.append(Finding(role: "kind.\(kind.rawValue)", background: name, ratio: ratio(rgba(foreground), on: rgba(background)), minimum: nonTextMinimum))
            }
        }
        let onAccent = ratio(rgba(tokens.onAccent), on: rgba(tokens.accent))
        out.append(Finding(role: "onAccent", background: "accent", ratio: onAccent, minimum: textMinimum))
        return out
    }
}
