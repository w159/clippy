import Foundation

// Every persisted UserDefaults key for AppSettings, plus the list wiped by
// resetAllToDefaults(). Key strings are the on-disk contract: never rename one.

extension AppSettings {
    /// UserDefaults key strings for every persisted setting.
    enum Keys {
            static let positionMode = "positionMode"
            static let panelWidth = "panelWidth"
            static let panelHeight = "panelHeight"
            static let rememberPanelSize = "rememberPanelSize"
            static let pollingIntervalMs = "pollingIntervalMs"
            static let maxHistoryItems = "maxHistoryItems"
            static let movePastedItemToTop = "movePastedItemToTop"
            static let pastePlainTextByDefault = "pastePlainTextByDefault"
            static let ignoredBundleIDs = "ignoredBundleIDs"
            static let lastPanelX = "lastPanelX"
            static let lastPanelY = "lastPanelY"
            static let appearanceMode = "appearanceMode"
            static let accentTheme = "accentTheme"
            static let panelMaterial = "panelMaterial"
            static let cardColorMode = "cardColorMode"
            static let showAppIcons = "showAppIcons"
            static let showSectionHeaders = "showSectionHeaders"
            static let captureImages = "captureImages"
            static let maxImageSizeMB = "maxImageSizeMB"
            static let captureSoundEnabled = "captureSoundEnabled"
            static let captureSoundName = "captureSoundName"  // legacy (classic enum rawValue)
            static let captureSoundID = "captureSoundID"
            static let captureSoundVolume = "captureSoundVolume"
            static let cardStyle = "cardStyle"
            static let cardTintStrength = "cardTintStrength"
            static let highContrastCardText = "highContrastCardText"
            static let fontFamily = "fontFamily"
            static let fontSizeBase = "fontSizeBase"
            // Theme system
            static let themePreset = "themePreset"
            static let panelOpacity = "panelOpacity"
            static let customIsDark = "customIsDark"
            static let customPanelHex = "customPanelHex"
            static let customScrollBgHex = "customScrollBgHex"
            static let customCardSurfaceHex = "customCardSurfaceHex"
            static let customCardBorderHex = "customCardBorderHex"
            static let customHeaderHex = "customHeaderHex"
            static let customFooterHex = "customFooterHex"
            static let customSidebarHex = "customSidebarHex"
            static let customScrollbarHex = "customScrollbarHex"
            static let customTextPrimaryHex = "customTextPrimaryHex"
            static let customTextSecondaryHex = "customTextSecondaryHex"
            static let customAccentHex = "customAccentHex"
            static let customSuccessHex = "customSuccessHex"
            static let customDangerHex = "customDangerHex"
            // AI / LLM integration
            static let aiEnabled = "aiEnabled"
            static let aiProvider = "aiProvider"
            static let aiModel = "aiModel"
            static let aiBaseURL = "aiBaseURL"
            static let aiAzureAPIVersion = "aiAzureAPIVersion"
            static let aiAutoSuggestTitles = "aiAutoSuggestTitles"
            static let aiAgentAllowScripts = "aiAgentAllowScripts"
            static let aiAgentAllowCodeExecution = "aiAgentAllowCodeExecution"
            static let aiAgentAllowWebSearch = "aiAgentAllowWebSearch"
            // 1Password integration
            static let onePasswordEnabled = "onePasswordEnabled"
            static let onePasswordVault = "onePasswordVault"
            static let onePasswordAutoClearClipboard = "onePasswordAutoClearClipboard"
            static let onePasswordAutoClearDelaySecs = "onePasswordAutoClearDelaySecs"
            // iCloud sync
            static let iCloudSyncEnabled = "iCloudSyncEnabled"
            // Clip click + keystroke actions
            static let clickCopyOnly = "clickCopyOnly"
            static let keystrokeSpeed = "keystrokeSpeed"
            static let keystrokeWarnThreshold = "keystrokeWarnThreshold"
            // MCP integration
            static let mcpEnabled = "mcpEnabled"
            static let mcpPort = "mcpPort"
            // Smart Suggestions (on-device, opt-in)
            static let suggestionsEnabled = "suggestionsEnabled"
            static let suggestionsLimit = "suggestionsLimit"
            static let suggestionsUseWindowText = "suggestionsUseWindowText"
            static let suggestionsAutoOpen = "suggestionsAutoOpen"
            // Panel behavior
            static let hideOnClickAway = "hideOnClickAway"
            static let allowMultipleCategories = "allowMultipleCategories"
            static let hideAfterPaste = "hideAfterPaste"
            static let hideOnEscape = "hideOnEscape"
            static let panelFloatLevel = "panelFloatLevel"
            static let panelPinned = "panelPinned"
            // Clip list layout
            static let clipColumns = "clipColumns"
            // File clips
            static let captureFiles = "captureFiles"
            static let maxFileSizeMB = "maxFileSizeMB"
            // Logging
            static let logLevel = "logLevel"

        /// Keys removed by `resetAllToDefaults()`.
        static let allPersisted: [String] = [
                Keys.positionMode, Keys.panelWidth, Keys.panelHeight, Keys.rememberPanelSize,
                Keys.pollingIntervalMs, Keys.maxHistoryItems, Keys.movePastedItemToTop,
                Keys.pastePlainTextByDefault, Keys.ignoredBundleIDs, Keys.appearanceMode,
                Keys.accentTheme, Keys.panelMaterial, Keys.cardColorMode, Keys.showAppIcons,
                Keys.showSectionHeaders, Keys.captureImages, Keys.maxImageSizeMB,
                Keys.captureSoundEnabled, Keys.captureSoundName, Keys.captureSoundID,
                Keys.captureSoundVolume, Keys.cardStyle, Keys.cardTintStrength,
                Keys.highContrastCardText, Keys.fontFamily, Keys.fontSizeBase, Keys.themePreset,
                Keys.panelOpacity, Keys.customIsDark, Keys.customPanelHex, Keys.customScrollBgHex,
                Keys.customCardSurfaceHex, Keys.customCardBorderHex, Keys.customHeaderHex,
                Keys.customFooterHex, Keys.customSidebarHex, Keys.customScrollbarHex,
                Keys.customTextPrimaryHex, Keys.customTextSecondaryHex, Keys.customAccentHex,
                Keys.customSuccessHex, Keys.customDangerHex, Keys.aiEnabled, Keys.aiProvider,
                Keys.aiModel, Keys.aiBaseURL, Keys.aiAzureAPIVersion, Keys.aiAutoSuggestTitles,
                Keys.aiAgentAllowScripts, Keys.aiAgentAllowCodeExecution, Keys.aiAgentAllowWebSearch,
                Keys.onePasswordEnabled, Keys.onePasswordVault, Keys.onePasswordAutoClearClipboard,
                Keys.onePasswordAutoClearDelaySecs, Keys.iCloudSyncEnabled, Keys.clickCopyOnly,
                Keys.keystrokeSpeed, Keys.keystrokeWarnThreshold, Keys.mcpEnabled, Keys.mcpPort,
                Keys.suggestionsEnabled, Keys.suggestionsLimit, Keys.suggestionsUseWindowText,
                Keys.suggestionsAutoOpen,
                Keys.hideOnClickAway, Keys.allowMultipleCategories, Keys.hideAfterPaste,
                Keys.hideOnEscape, Keys.panelFloatLevel, Keys.panelPinned, Keys.clipColumns,
                Keys.captureFiles, Keys.maxFileSizeMB, Keys.logLevel,
                // Grid/status/hotkey preferences are stored by their owning subsystems,
                // but belong to the all-settings reset contract.
                GridPreferences.columnModeKey, GridPreferences.densityKey,
                StatusItemPreferences.clickBehaviorKey,
        ] + HotKeyAction.allCases.flatMap { [$0.defaultsKey, $0.disabledKey] }
    }
}
