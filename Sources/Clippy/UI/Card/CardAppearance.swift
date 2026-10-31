import Foundation

/// Pure mapping from the Appearance > Cards settings to the values the card
/// draws with, so every control has one tested effect (no SwiftUI here).
struct CardAppearance: Equatable {
    /// What fills the card face.
    enum Face: Equatable { case solid, clear }
    /// The resting outline: none (plain), a hairline (filled), or a stronger one (bordered).
    enum Edge: Equatable { case none, hairline, strong }
    /// Where the optional face tint comes from.
    enum Tint: Equatable { case none, sourceApp, kind, accent }

    /// Highest tint strength the slider offers, in percent.
    static let maxTintPercent = 20

    let face: Face
    let edge: Edge
    let tint: Tint
    /// 0...0.2 opacity of the tint over the face; 0 when `tint` is `.none`.
    let tintOpacity: Double
    /// Secondary lines (app name, time, link URL) use the primary text color.
    let usesPrimaryForSecondaryText: Bool

    static func resolve(style: CardStyle, colorMode: CardColorMode, tintStrength: Int, highContrast: Bool) -> CardAppearance {
        let percent = min(max(tintStrength, 0), maxTintPercent)
        let tint: Tint
        switch colorMode {
        case .byApp: tint = .sourceApp
        case .byKind: tint = .kind
        case .accent: tint = .accent
        case .neutral: tint = .none
        }
        // Plain cards have no face to tint; a 0% slider means no tint either.
        let tinted = style != .plain && tint != .none && percent > 0
        return CardAppearance(
            face: style == .filled ? .solid : .clear,
            edge: style == .filled ? .hairline : (style == .bordered ? .strong : .none),
            tint: tinted ? tint : .none,
            tintOpacity: tinted ? Double(percent) / 100 : 0,
            usesPrimaryForSecondaryText: highContrast
        )
    }
}
