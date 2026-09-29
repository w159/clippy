import AppKit
import SwiftUI

// The theming vocabulary: appearance, accent, surface material, card style,
// typography, and how cards get their color. All stored in AppSettings; views
// read these enums directly.

// MARK: - Appearance mode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means inherit the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Accent color

enum AccentTheme: String, CaseIterable, Identifiable {
    // clippyAmber is listed first so it appears at the top of pickers.
    case clippyAmber
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clippyAmber: return "Clippy Amber"
        case .system: return "System"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .clippyAmber: return Color(red: 0xE0 / 255.0, green: 0xA2 / 255.0, blue: 0x3C / 255.0)
        case .system: return Color(nsColor: .controlAccentColor)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .teal: return Color(nsColor: .systemTeal)
        case .graphite: return Color(nsColor: .systemGray)
        }
    }
}

// MARK: - Panel background

enum PanelMaterialStyle: String, CaseIterable, Identifiable {
    case ultraThin
    case thin
    case regular
    case thick
    case opaque

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraThin: return "Glass (ultra thin)"
        case .thin: return "Glass (thin)"
        case .regular: return "Frosted"
        case .thick: return "Frosted (thick)"
        case .opaque: return "Solid"
        }
    }

    /// nil means use the solid window background color instead of a blur material.
    var material: Material? {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .opaque: return nil
        }
    }

    /// LAY-14: the real consumer of the persisted `panelMaterial` setting.
    /// The five raw values are preserved; they resolve to one of three panel
    /// backdrops (docs/design/01-principles-and-tokens.md section 2.2):
    /// ultraThin/thin -> Liquid Glass, regular/thick -> AppKit vibrancy,
    /// opaque -> solid. See `ThemedPanelBackground`.
    var backdrop: PanelBackdropStyle {
        switch self {
        case .ultraThin, .thin: return .glass
        case .regular, .thick: return .vibrancy
        case .opaque: return .solid
        }
    }
}

// MARK: - Card style

/// Controls how card backgrounds are rendered.
enum CardStyle: String, CaseIterable, Identifiable {
    /// Fully opaque card face using the standard control background color.
    case filled
    /// Transparent card face with a visible border only.
    case bordered
    /// No card chrome at all; items float directly on the panel background.
    case plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .filled: return "Filled"
        case .bordered: return "Bordered"
        case .plain: return "Plain"
        }
    }
}

// MARK: - Card color mode

enum CardColorMode: String, CaseIterable, Identifiable {
    case byApp
    case byKind
    case accent
    case neutral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .byApp: return "By source app"
        case .byKind: return "By content type"
        case .accent: return "Accent color"
        case .neutral: return "Neutral"
        }
    }
}

// MARK: - Font family

/// Panel UI font family choices. The system font is always available. Named
/// families are verified against NSFontManager at init time; any that are not
/// installed fall back to the system font so no configuration is ever invalid.
enum PanelFontFamily: String, CaseIterable, Identifiable {
    case systemDefault
    case helveticaNeue = "Helvetica Neue"
    case sfMono = "SF Mono"
    case georgia = "Georgia"
    case menlo = "Menlo"
    case avenir = "Avenir"
    case optima = "Optima"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemDefault: return "System default"
        case .helveticaNeue: return "Helvetica Neue"
        case .sfMono: return "SF Mono"
        case .georgia: return "Georgia"
        case .menlo: return "Menlo"
        case .avenir: return "Avenir"
        case .optima: return "Optima"
        }
    }

    /// The PostScript/family name passed to Font.custom, or nil for .systemDefault.
    var familyName: String? {
        switch self {
        case .systemDefault: return nil
        default: return rawValue
        }
    }

    /// True if the named family is present in the running system. Always true
    /// for .systemDefault. Call this before showing a family in the picker so
    /// the list only contains fonts the system actually has.
    var isAvailable: Bool {
        guard let name = familyName else { return true }
        return Self.installedFamilies.contains(name)
    }

    /// LAY-13: the installed family set, read once. `availableFontFamilies`
    /// builds a fresh array on every call and `isAvailable` runs on every
    /// PanelTypography.make, i.e. once per Text per render. Fonts installed
    /// while the app runs are picked up on next launch, which is acceptable
    /// for a picker of well-known system families.
    private static let installedFamilies: Set<String> = Set(NSFontManager.shared.availableFontFamilies)
}

// MARK: - Typography helper

/// Central typography resolver. All panel UI text routes through one of these
/// computed Font values so the user's font family and base size apply everywhere.
///
/// Usage:
///   Text(foo).font(PanelTypography.body(settings))
///
/// Roles and their size offset relative to the base size:
///   body     +0  (clip preview text, normal labels)
///   title    +0, weight .medium (clip title / header label)
///   metadata -1  (date stamps, kind badges, section headers)
///   micro    -2  (count badges, caption2 equivalents)
@MainActor
struct PanelTypography {
    // Prevent instantiation; all members are static helpers.
    private init() {}

    /// The clip preview text and general body copy.
    static func body(_ settings: AppSettings) -> Font {
        make(size: CGFloat(settings.fontSizeBase), weight: .regular, settings: settings)
    }

    /// The clip title / card header row label.
    static func title(_ settings: AppSettings) -> Font {
        make(size: CGFloat(settings.fontSizeBase), weight: .medium, settings: settings)
    }

    /// Dates, kind badges, section header labels.
    static func metadata(_ settings: AppSettings) -> Font {
        make(size: CGFloat(settings.fontSizeBase) - 1, weight: .regular, settings: settings)
    }

    /// Count badges, caption2-equivalent fine print.
    static func micro(_ settings: AppSettings) -> Font {
        make(size: max(9, CGFloat(settings.fontSizeBase) - 2), weight: .regular, settings: settings)
    }

    /// NSFont matching the title role, for AppKit-backed fields (the rename
    /// editor) so inline editing keeps the same typography as the label.
    static func nsTitleFont(_ settings: AppSettings) -> NSFont {
        let size = CGFloat(settings.fontSizeBase)
        if let family = settings.fontFamily.familyName,
           settings.fontFamily.isAvailable,
           let custom = NSFont(name: family, size: size) {
            return custom
        }
        return NSFont.systemFont(ofSize: size, weight: .medium)
    }

    // MARK: - Private

    private static func make(size: CGFloat, weight: Font.Weight, settings: AppSettings) -> Font {
        guard let family = settings.fontFamily.familyName,
              settings.fontFamily.isAvailable
        else {
            // System font path: use Font.system so Dynamic Type and weight work normally.
            return .system(size: size, weight: weight)
        }
        // Custom family: Font.custom with a fixed size. Weight is applied as a modifier
        // because Font.custom does not accept a weight parameter directly.
        return .custom(family, size: size).weight(weight)
    }
}

// MARK: - Category palette

/// Fixed hexes for category colors. Stored in the DB as text, so they must
/// be stable values rather than dynamic system colors.
enum CategoryPalette {
    static let hexes: [String] = [
        "#007AFF", "#AF52DE", "#FF2D55", "#FF3B30", "#FF9500",
        "#FFCC00", "#34C759", "#30B0C7", "#5E5CE6", "#8E8E93",
    ]
}

