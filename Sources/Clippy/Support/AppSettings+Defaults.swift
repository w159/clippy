import Foundation

// UserDefaults default registration and sound-id migration for AppSettings.

extension AppSettings {
    /// Default panel size: 640 wide in 2.2.0; 760 is the width the list, the sidebar and the detail pane need.
    nonisolated static let defaultPanelWidth = 760.0
    nonisolated static let defaultPanelHeight = 480.0
    /// The size 2.4.0 registered as its default and wrote over saved smaller sizes.
    nonisolated static let v240PanelWidth = 920.0
    nonisolated static let v240PanelHeight = 560.0
    /// One-time flag for `lowerBumpedPanelSize`.
    nonisolated static let panelSizeLowerKey = "panel.sizeLower.v241"

    /// First run of this version: a saved panel size of exactly 920 x 560 (what 2.4.0 wrote) goes back to the
    /// new default. Any other saved size is the user's own and is kept. Guarded by `panelSizeLowerKey`, so a later
    /// manual resize to 920 x 560 is left alone.
    static func lowerBumpedPanelSize(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: panelSizeLowerKey) else { return }
        if defaults.double(forKey: Keys.panelWidth) == v240PanelWidth,
           defaults.double(forKey: Keys.panelHeight) == v240PanelHeight {
            defaults.set(defaultPanelWidth, forKey: Keys.panelWidth)
            defaults.set(defaultPanelHeight, forKey: Keys.panelHeight)
        }
        defaults.set(true, forKey: panelSizeLowerKey)
    }

    /// Register every default so UserDefaults returns correct values before the user touches a setting.
    /// Must run before any @AppDefault wrapper is read.
    static func registerDefaults(_ defaults: UserDefaults) {
        defaults.register(defaults: [
                Keys.positionMode: PanelPositionMode.caret.rawValue,
                Keys.panelWidth: defaultPanelWidth,
                Keys.panelHeight: defaultPanelHeight,
                Keys.rememberPanelSize: true,
                PreviewColumnPreferences.enabledKey: PreviewColumnPreferences.defaultEnabled,
                Keys.pollingIntervalMs: 200.0,
                Keys.maxHistoryItems: 500,
                Keys.movePastedItemToTop: false,
                Keys.pastePlainTextByDefault: false,
                Keys.ignoredBundleIDs: [String](),
                Keys.appearanceMode: AppearanceMode.system.rawValue,
                Keys.accentTheme: AccentTheme.clippyAmber.rawValue,
                // Solid is the default: fully opaque, full-contrast, no glass effect.
                Keys.panelMaterial: PanelMaterialStyle.opaque.rawValue,
                Keys.cardColorMode: CardColorMode.byApp.rawValue,
                Keys.showAppIcons: true,
                Keys.showSectionHeaders: true,
                Keys.captureImages: true,
                Keys.maxImageSizeMB: 20,
                Keys.captureSoundEnabled: false,
                Keys.captureSoundID: SoundCatalog.defaultID,
                Keys.captureSoundVolume: 50,
                Keys.cardStyle: CardStyle.filled.rawValue,
                Keys.cardTintStrength: 8,
                Keys.highContrastCardText: false,
                Keys.fontFamily: PanelFontFamily.systemDefault.rawValue,
                Keys.fontSizeBase: 13,
                // Clean Light. "Automatic" (Clean Light / GitHub Dark by system appearance) stays selectable.
                Keys.themePreset: ThemePreset.automatic.rawValue,
                Keys.panelOpacity: 1.0,
                Keys.customIsDark: false,
                // Per-token overrides default to "" (no override) so a fresh install
                // matches the selected preset exactly. See the override props above.
                Keys.customPanelHex: "",
                Keys.customScrollBgHex: "",
                Keys.customCardSurfaceHex: "",
                Keys.customCardBorderHex: "",
                Keys.customHeaderHex: "",
                Keys.customFooterHex: "",
                Keys.customSidebarHex: "",
                Keys.customScrollbarHex: "",
                Keys.customTextPrimaryHex: "",
                Keys.customTextSecondaryHex: "",
                Keys.customAccentHex: "",
                Keys.customSuccessHex: "",
                Keys.customDangerHex: "",
                Keys.aiEnabled: false,
                Keys.aiProvider: "appleIntelligence",
                Keys.aiModel: "",
                Keys.aiBaseURL: "",
                Keys.aiAzureAPIVersion: "2024-10-21",
                Keys.aiAutoSuggestTitles: false,
                Keys.aiAgentAllowScripts: false,
                Keys.aiAgentAllowCodeExecution: false,
                Keys.aiAgentAllowWebSearch: false,
                Keys.onePasswordEnabled: false,
                Keys.onePasswordVault: "Clippy",
                Keys.onePasswordAutoClearClipboard: true,
                Keys.onePasswordAutoClearDelaySecs: 90,
                Keys.iCloudSyncEnabled: false,
                Keys.clickCopyOnly: false,
                Keys.keystrokeSpeed: KeystrokeSpeed.balanced.rawValue,
                Keys.keystrokeWarnThreshold: 2000,
                Keys.mcpEnabled: false,
                Keys.mcpPort: 51764,
                Keys.suggestionsEnabled: false,
                Keys.suggestionsLimit: 8,
                Keys.suggestionsUseWindowText: true,
                Keys.suggestionsAutoOpen: false,
                // Panel behavior: all defaults preserve the pre-existing behavior exactly.
                Keys.hideOnClickAway: false,
                Keys.allowMultipleCategories: false,
                Keys.hideAfterPaste: true,
                Keys.hideOnEscape: true,
                Keys.panelFloatLevel: PanelFloatLevel.alwaysOnTop.rawValue,
                Keys.panelPinned: false,
                Keys.logLevel: ClippyLog.LogLevel.info.rawValue,
        ])
    }

    /// Resolve the stored sound id, migrating the legacy classic-enum key the
    /// previous build wrote ("captureSoundName" = "Tink", "Pop", ...).
    static func resolveSoundID(_ defaults: UserDefaults) -> String {
        let candidate: String
        if let id = defaults.string(forKey: Keys.captureSoundID), !id.isEmpty {
            candidate = id
        } else if let legacy = defaults.string(forKey: Keys.captureSoundName), !legacy.isEmpty {
            candidate = "system:\(legacy)"
        } else {
            candidate = SoundCatalog.defaultID
        }
        // Reconcile against the live catalog: a sound removed by an OS update or a
        // deleted custom sound would otherwise leave the picker blank and capture
        // playback silent. resolvedID falls back to the default for a vanished id.
        return SoundCatalog.resolvedID(for: candidate)
    }
}
