import SwiftUI

/// Semantic design tokens resolved from the unchanged persisted `ThemeTokens`.
/// New views read `@Environment(\.clippyTokens)`; legacy views can continue to
/// read `ThemeTokens` and `PanelTypography` with no value changes.
struct ClippyTokens {
    /// Legacy values retained byte-for-byte from the source palette.
    let legacy: ThemeTokens
    /// Main content and list background.
    let surface: Color
    /// Cards and solid fallback for floating surfaces.
    let surfaceElevated: Color
    /// Inset controls and secondary content.
    let surfaceInset: Color
    /// Dense navigation rail and sidebar.
    let surfaceSidebar: Color
    /// Subtle separator / card stroke.
    let stroke: Color
    /// High-contrast boundary for controls and focus.
    let strokeStrong: Color
    /// Main readable content.
    let textPrimary: Color
    /// Secondary labels, never low-contrast tertiary gray.
    let textSecondary: Color
    /// Tertiary text, contrast-adjusted to normal-text AA.
    let textTertiary: Color
    /// Meaningful action fill.
    let accent: Color
    /// Accessible accent foreground/link color.
    let accentText: Color
    /// Foreground with AA contrast on `accent`.
    let onAccent: Color
    /// Selected control surface, independent of focus.
    let selection: Color
    /// Positive outcome.
    let success: Color
    /// Caution / unavailable reason.
    let warning: Color
    /// Destructive or failed outcome.
    let danger: Color
    /// Opaque neutral fill for masked content.
    let masked: Color
    /// Scroll thumb, contrast-adjusted for the primary surface.
    let scrollbar: Color
    /// Effective theme appearance, preserved for legacy/AppKit bridges.
    let scheme: ColorScheme
    /// Semantic focus ring; deliberately separate from selection.
    var focusRing: Color { accentText }

    /// Returns a contrast-tested, theme-specific hue for a clip kind.
    func kind(_ kind: ClipKindStyle) -> Color { kindColors[kind] ?? textSecondary }

    /// Radius, spacing, elevation and motion scales shared by all controls.
    let metrics: ClippyMetrics
    private let kindColors: [ClipKindStyle: Color]
    /// Surfaces on which strokes/icons must meet the 3:1 non-text target.
    let strokeOnlySurfaces: Set<String>

    /// Resolves semantic roles from the legacy source of truth. The source
    /// palette is not modified. Increase Contrast raises non-text roles to a
    /// stronger black/white companion and text roles remain WCAG AA.
    static func resolve(from tokens: ThemeTokens, contrast: ColorSchemeContrast = .standard) -> ClippyTokens {
        let dark = tokens.isDark
        let baseSurfaces: [(String, Color)] = [
            ("surface", tokens.scrollBackground), ("surfaceElevated", tokens.cardSurface),
            ("surfaceInset", tokens.headerBar), ("surfaceSidebar", tokens.sidebar),
        ]
        func rgba(_ color: Color) -> RGBA { RGBA(color: color, isDark: dark) ?? (dark ? .black : .white) }
        let surfacePairs = baseSurfaces.map { ($0.0, rgba($0.1)) }
        let backgrounds = surfacePairs.map(\.1)
        let accent = rgba(tokens.accent)
        // selection = 12% accent tint over the surface (was accent.mixed(with: surface, 0.12), i.e. 88% accent:
        // body text on it measured 2.2-4.3:1). Now a light tint so text keeps AA on it.
        let selectionBase = backgrounds[0].mixed(with: accent, 0.12)
        let allSurfaces = backgrounds + [selectionBase]
        let strongerMinimum = contrast == .increased ? ContrastAudit.enhancedText : ContrastAudit.textMinimum
        let primary = rgba(tokens.textPrimary)
        let secondary = rgba(tokens.textSecondary)
        let safePrimary = ContrastAudit.adjust(primary, against: allSurfaces, minimum: strongerMinimum)
        let safeSecondary = ContrastAudit.adjust(secondary, against: allSurfaces, minimum: strongerMinimum)
        let safeAccentText = ContrastAudit.adjust(accent, against: allSurfaces, minimum: strongerMinimum)
        let maxContrastForeground = ContrastAudit.ratio(.black, on: accent) >= ContrastAudit.ratio(.white, on: accent) ? RGBA.black : RGBA.white
        let selection = ContrastAudit.adjust(selectionBase, against: [backgrounds[0]], minimum: 1.0)
        let strokeMinimum = contrast == .increased ? 4.5 : ContrastAudit.nonTextMinimum
        let safeStroke = ContrastAudit.adjust(rgba(tokens.cardBorder), against: allSurfaces, minimum: strokeMinimum)
        let strokeStrong = ContrastAudit.adjust(safeStroke, against: allSurfaces, minimum: contrast == .increased ? 4.5 : strokeMinimum)
        let scroll = ContrastAudit.adjust(rgba(tokens.scrollbar), against: allSurfaces, minimum: strokeMinimum)
        let kindPalette: [ClipKindStyle: RGBA] = dark ? [
            .text: RGBA(hex: "#84B9FF")!, .image: RGBA(hex: "#E59BFF")!, .file: RGBA(hex: "#FFD166")!,
            .link: RGBA(hex: "#62D6C7")!, .email: RGBA(hex: "#FF9A8B")!, .color: RGBA(hex: "#E5A3D8")!,
            .code: RGBA(hex: "#A9D18E")!, .richText: RGBA(hex: "#A8B4FF")!,
        ] : [
            .text: RGBA(hex: "#0759A6")!, .image: RGBA(hex: "#7B3294")!, .file: RGBA(hex: "#815900")!,
            .link: RGBA(hex: "#00776A")!, .email: RGBA(hex: "#A33427")!, .color: RGBA(hex: "#8A397D")!,
            .code: RGBA(hex: "#36752B")!, .richText: RGBA(hex: "#4F54A5")!,
        ]
        let kinds = Dictionary(uniqueKeysWithValues: kindPalette.map { key, value in
            (key, ContrastAudit.adjust(value, against: backgrounds, minimum: strokeMinimum).color)
        })
        let selectionColor = selection.color
        let safeSuccess = ContrastAudit.adjust(rgba(Color(nsColor: .systemGreen)), against: backgrounds, minimum: strongerMinimum)
        let safeDanger = ContrastAudit.adjust(rgba(tokens.danger), against: backgrounds, minimum: strongerMinimum)
        return ClippyTokens(
            legacy: tokens,
            surface: tokens.scrollBackground,
            surfaceElevated: tokens.cardSurface,
            surfaceInset: tokens.headerBar,
            surfaceSidebar: tokens.sidebar,
            stroke: safeStroke.color,
            strokeStrong: strokeStrong.color,
            textPrimary: safePrimary.color,
            textSecondary: safeSecondary.color,
            textTertiary: safeSecondary.color,
            accent: tokens.accent,
            accentText: safeAccentText.color,
            onAccent: maxContrastForeground.color,
            selection: selectionColor,
            success: safeSuccess.color,
            warning: safeStatusColor(hex: dark ? "#F0B24A" : "#8A5A00", on: backgrounds, minimum: strongerMinimum),
            danger: safeDanger.color,
            masked: dark ? Color(themeHex: "#3A3A3E") : Color(themeHex: "#D9D9DE"),
            scrollbar: scroll.color,
            scheme: dark ? .dark : .light,
            metrics: ClippyMetrics(dark: dark),
            kindColors: kinds,
            strokeOnlySurfaces: Set(surfacePairs.map(\.0))
        )
    }

    private static func safeStatusColor(hex: String, on backgrounds: [RGBA], minimum: Double) -> Color {
        ContrastAudit.adjust(RGBA(hex: hex)!, against: backgrounds, minimum: minimum).color
    }
}

/// Clip content-kind identifiers used for semantic hue and icon styling.
enum ClipKindStyle: String, CaseIterable, Hashable, Identifiable {
    case text, image, file, link, email, color, code, richText
    var id: String { rawValue }
}

/// Shared radius, spacing, elevation and motion values. Spacing is a strict 4pt grid.
struct ClippyMetrics {
    let radius: RadiusScale
    let space: SpacingScale
    let elevation: ElevationScale
    let motion: MotionSpec

    init(dark: Bool) {
        radius = RadiusScale()
        space = SpacingScale()
        elevation = ElevationScale(dark: dark)
        motion = MotionSpec()
    }
}

/// Corner-radius scale in points; `full` means capsule, not an arbitrary radius.
struct RadiusScale {
    let xs: CGFloat = 4
    let sm: CGFloat = 8
    let md: CGFloat = 12
    let lg: CGFloat = 16
    let xl: CGFloat = 24
}

/// The shared 4-point spacing grid.
struct SpacingScale {
    let zero: CGFloat = 0
    let one: CGFloat = 4
    let two: CGFloat = 8
    let three: CGFloat = 12
    let four: CGFloat = 16
    let five: CGFloat = 20
    let six: CGFloat = 24
    let eight: CGFloat = 32
    let ten: CGFloat = 40
}

/// Three restrained elevation treatments; e2 is reserved for floating controls.
struct ElevationScale {
    let e0: CGFloat = 0
    let e1: CGFloat = 2
    let e2: CGFloat = 24
    let color: Color

    init(dark: Bool) { color = Color.black.opacity(dark ? 0.5 : 0.16) }
}

/// Semantic type styles mapped to scalable SwiftUI text styles.
enum ClippyTextRole: CaseIterable {
    case display, title, body, bodyEmphasis, metadata, caption, micro, code

    var textStyle: Font.TextStyle {
        switch self {
        case .display: return .title2
        case .title: return .headline
        case .body, .bodyEmphasis, .code: return .body
        case .metadata: return .callout
        case .caption: return .caption
        case .micro: return .caption2
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .title: return .semibold
        case .bodyEmphasis, .micro: return .medium
        default: return .regular
        }
    }

    var design: Font.Design { self == .code ? .monospaced : .default }

    /// System text style keeps Dynamic Type scaling. The optional family and
    /// multiplier are supplied by ClippyTypography, not hard-coded in controls.
    func font(family: PanelFontFamily = .systemDefault, scale: CGFloat = 1) -> Font {
        if let name = family.familyName, family.isAvailable {
            return .custom(name, size: nominalSize * scale, relativeTo: textStyle).weight(weight)
        }
        return .system(textStyle, design: design, weight: weight)
    }

    private var nominalSize: CGFloat {
        switch self {
        case .display: return 22
        case .title: return 17
        case .body, .bodyEmphasis, .code: return 13
        case .metadata: return 12
        case .caption: return 11
        case .micro: return 10
        }
    }
}
