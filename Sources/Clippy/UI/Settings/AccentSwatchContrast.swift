import SwiftUI

/// Picks the checkmark color for an accent swatch: whichever of black or white
/// has the higher contrast ratio against the swatch, so the mark stays legible
/// on light accents (yellow, amber) as well as dark ones.
enum AccentSwatchContrast {
    static func markColor(on fill: RGBA) -> RGBA {
        let onBlack = ContrastAudit.ratio(.black, on: fill)
        let onWhite = ContrastAudit.ratio(.white, on: fill)
        return onBlack > onWhite ? .black : .white
    }

    /// Resolved for the swatch's accent under the current appearance; white when it cannot be resolved.
    static func markColor(for accent: Color, isDark: Bool) -> Color {
        guard let fill = RGBA(color: accent, isDark: isDark) else { return .white }
        return markColor(on: fill).color
    }
}
