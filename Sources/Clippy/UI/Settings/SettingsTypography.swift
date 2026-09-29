import AppKit
import SwiftUI

// Settings-window typography helpers that track the user's panel font family.

/// Settings-window typography. Audit finding: the settings chrome used raw
/// .font(.system(size:)), so the user's panel font family never applied here.
/// These helpers mirror PanelTypography's approach (respect fontFamily and
/// fontSizeBase) so the settings window follows the same font choice as the
/// panel. Sizes are fixed per role (the settings layout is denser than the
/// panel and should not scale with fontSizeBase), but the family tracks the
/// user's choice. System-default falls back to .system so semantic designs
/// (rounded wordmark) still apply.
@MainActor
enum SettingsTypography {
    // Caseless enum used as a namespace; no instances can be constructed.

    /// Build a font in the user's chosen family, falling back to the system font
    /// (with an optional design) when .systemDefault is selected.
    private static func make(size: CGFloat, weight: Font.Weight,
                            design: Font.Design? = nil,
                            _ settings: AppSettings) -> Font {
        guard let family = settings.fontFamily.familyName,
              settings.fontFamily.isAvailable
        else {
            if let design { return .system(size: size, weight: weight, design: design) }
            return .system(size: size, weight: weight)
        }
        return .custom(family, size: size).weight(weight)
    }

    /// The "Clippy" wordmark in the sidebar header.
    static func brand(_ settings: AppSettings) -> Font {
        make(size: 16, weight: .bold, design: .rounded, settings)
    }

    /// The "Settings" subtitle under the wordmark.
    static func brandSubtitle(_ settings: AppSettings) -> Font {
        make(size: 11, weight: .regular, settings)
    }

    /// The glyph inside a sidebar section tile.
    static func sidebarIcon(_ settings: AppSettings) -> Font {
        make(size: 11, weight: .semibold, settings)
    }

    /// A sidebar row label. Weight tracks selection.
    static func sidebarRow(_ settings: AppSettings, selected: Bool) -> Font {
        make(size: 13, weight: selected ? .semibold : .regular, settings)
    }

    /// The footer version line.
    static func footer(_ settings: AppSettings) -> Font {
        make(size: 10, weight: .regular, settings)
    }

    /// The large section title at the top of the detail pane.
    static func detailTitle(_ settings: AppSettings) -> Font {
        make(size: 22, weight: .bold, design: .rounded, settings)
    }

    /// The checkmark on a selected accent swatch.
    static func swatchCheck(_ settings: AppSettings) -> Font {
        make(size: 9, weight: .bold, settings)
    }
}
