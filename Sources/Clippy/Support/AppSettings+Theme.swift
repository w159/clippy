import SwiftUI

// Theme-derived computed properties of AppSettings. The cache storage
// (cachedTokensStorage/cachedTokenSignatureStorage) stays in AppSettings.swift because
// extensions cannot hold stored properties.

extension AppSettings {
    var theme: ThemeTokens {
        let signature = tokenSignature
        if let cached = cachedTokensStorage, signature == cachedTokenSignatureStorage {
            return cached
        }
        let resolved = Theme.tokens(self)
        cachedTokensStorage = resolved
        cachedTokenSignatureStorage = signature
        return resolved
    }

    /// Hash of every input Theme.tokens consults, so the cache invalidates the
    /// instant any of them changes. accentColor derives from accentTheme, so
    /// accentTheme alone covers the accent path.
    private var tokenSignature: Int {
        var hasher = Hasher()
        hasher.combine(themePreset)
        hasher.combine(customIsDark)
        hasher.combine(appearanceMode)
        hasher.combine(accentTheme)
        hasher.combine(customPanelHex)
        hasher.combine(customScrollBgHex)
        hasher.combine(customCardSurfaceHex)
        hasher.combine(customCardBorderHex)
        hasher.combine(customHeaderHex)
        hasher.combine(customFooterHex)
        hasher.combine(customSidebarHex)
        hasher.combine(customScrollbarHex)
        hasher.combine(customTextPrimaryHex)
        hasher.combine(customTextSecondaryHex)
        hasher.combine(customAccentHex)
        hasher.combine(customSuccessHex)
        hasher.combine(customDangerHex)
        hasher.combine(Theme.appearanceEpoch)
        return hasher.finalize()
    }

    var accentColor: Color { accentTheme.color }
}
