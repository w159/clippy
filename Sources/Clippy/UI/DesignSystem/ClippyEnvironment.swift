import SwiftUI

/// Environment key for theme-resolved semantic tokens.
private struct ClippyTokensKey: EnvironmentKey {
    static let defaultValue = ClippyTokens.resolve(from: Theme.customSeed)
}

/// Environment key for the app's chosen text-size multiplier.
private struct ClippyTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = ClippyTextScale.multiplier
}

/// Environment key for the existing user-selected font family.
private struct ClippyFontFamilyKey: EnvironmentKey {
    static let defaultValue = PanelFontFamily.systemDefault
}

/// EnvironmentValues bridge used by all redesigned views.
extension EnvironmentValues {
    /// The semantic design-system color and metric tokens.
    var clippyTokens: ClippyTokens {
        get { self[ClippyTokensKey.self] }
        set { self[ClippyTokensKey.self] = newValue }
    }

    /// User-selected text multiplier, composed with Dynamic Type scaling.
    var clippyTextScale: CGFloat {
        get { self[ClippyTextScaleKey.self] }
        set { self[ClippyTextScaleKey.self] = min(max(newValue, 0.75), 1.5) }
    }

    /// User's selected font family, resolved once at the app design-system root.
    var clippyFontFamily: PanelFontFamily {
        get { self[ClippyFontFamilyKey.self] }
        set { self[ClippyFontFamilyKey.self] = newValue }
    }
}

/// View entry point that resolves live theme tokens and injects the shared environment.
extension View {
    /// Injects tokens derived from the current AppSettings and accessibility contrast.
    func clippyDesignSystem() -> some View {
        modifier(ClippyDesignSystemEnvironment())
    }

    /// Injects explicit tokens (useful for previews and nested themed surfaces).
    func clippyTokens(_ tokens: ClippyTokens) -> some View {
        environment(\.clippyTokens, tokens)
    }
}

/// Resolves settings at the root, with environment-driven accessibility preferences.
private struct ClippyDesignSystemEnvironment: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .environment(\.clippyTokens, ClippyTokens.resolve(from: settings.theme, contrast: contrast))
            .environment(\.clippyTextScale, ClippyTextScale.multiplier)
            .environment(\.clippyFontFamily, settings.fontFamily)
    }
}

/// Prefixed UserDefaults-backed text multiplier for the design system.
enum ClippyTextScale {
    /// Existing UI does not change until a user explicitly sets this preference.
    static let userDefaultsKey = "designSystem.textScale"

    /// Validated 0.75...1.5 multiplier; invalid stored values safely default to 1.
    static var multiplier: CGFloat {
        let stored = UserDefaults.standard.object(forKey: userDefaultsKey) as? Double ?? 1
        return CGFloat(validatedMultiplier(stored))
    }

    /// Returns the supported multiplier, or 1 for invalid/unset values.
    static func validatedMultiplier(_ value: Double?) -> Double {
        guard let value, value.isFinite, (0.75...1.5).contains(value) else { return 1 }
        return value
    }

    /// Stores a validated user multiplier. Returns false when the input is invalid.
    @discardableResult
    static func setMultiplier(_ value: CGFloat) -> Bool {
        guard validatedMultiplier(Double(value)) == Double(value) else { return false }
        UserDefaults.standard.set(Double(value), forKey: userDefaultsKey)
        return true
    }
}

/// Environment-aware font helper for semantic roles.
struct ClippyTypography {
    @Environment(\.clippyTextScale) private var scale
    @Environment(\.clippyFontFamily) private var family

    /// Scalable font for the requested role, preserving current font-family settings.
    func font(_ role: ClippyTextRole) -> Font {
        role.font(family: family, scale: scale)
    }
}
