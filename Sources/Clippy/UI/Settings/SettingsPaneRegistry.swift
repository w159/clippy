import SwiftUI

// The list of settings panes, their persisted keys (for per-pane reset and
// export/import) and the view each one instantiates.

/// Identifies one settings pane, in sidebar order.
enum SettingsPaneID: String, CaseIterable, Identifiable {
    case general, appearance, capture, preview, pasteStack, snippets, ai, intelligence, semantic, security, data,
         integrations, automation, scripts, ocr, editor, about

    var id: String { rawValue }

    /// Sidebar and header title.
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .capture: return "Capture"
        case .preview: return "Preview"
        case .pasteStack: return "Paste Stack"
        case .snippets: return "Snippets"
        case .semantic: return "Semantic Search"
        case .automation: return "Automation"
        case .ai: return "AI"
        case .intelligence: return "Suggestions"
        case .security: return "Security"
        case .data: return "Data"
        case .integrations: return "Integrations"
        case .scripts: return "Scripts"
        case .ocr: return "OCR"
        case .editor: return "Editor"
        case .about: return "About"
        }
    }

    /// SF Symbol for the sidebar row.
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .capture: return "doc.on.clipboard"
        case .preview: return "eye"
        case .pasteStack: return "square.stack.3d.up"
        case .snippets: return "text.append"
        case .semantic: return "sparkle.magnifyingglass"
        case .automation: return "command"
        case .ai: return "sparkles"
        case .intelligence: return "brain.head.profile"
        case .security: return "lock.shield"
        case .data: return "externaldrive"
        case .integrations: return "puzzlepiece.extension"
        case .scripts: return "terminal"
        case .ocr: return "text.viewfinder"
        case .editor: return "square.and.pencil"
        case .about: return "info.circle"
        }
    }

    /// UserDefaults keys this pane owns. Drives "Reset this pane" and export/import.
    /// Panes owned by other areas list only keys registered in AppSettings/CapturePreferences.
    var keys: [String] {
        typealias Keys = AppSettings.Keys
        typealias Capture = CapturePreferences.Key
        switch self {
        case .general:
            return [Keys.pastePlainTextByDefault, Keys.movePastedItemToTop, Keys.clickCopyOnly, Keys.keystrokeSpeed,
                    Keys.keystrokeWarnThreshold, Keys.maxHistoryItems, Keys.allowMultipleCategories, Keys.hideOnClickAway,
                    Keys.hideAfterPaste, Keys.hideOnEscape, Keys.panelFloatLevel, Keys.panelPinned, Keys.logLevel,
                    ExternalEditorPreference.defaultsKey, StatusItemPreferences.clickBehaviorKey]
                + HotKeyAction.allCases.flatMap { [$0.defaultsKey, $0.disabledKey] }
        case .appearance:
            return [Keys.themePreset, Keys.appearanceMode, Keys.accentTheme, Keys.panelMaterial, Keys.panelOpacity,
                    Keys.customIsDark, Keys.cardStyle, Keys.cardColorMode, Keys.cardTintStrength,
                    Keys.highContrastCardText, Keys.showAppIcons, Keys.showSectionHeaders, Keys.fontFamily,
                    Keys.fontSizeBase, Keys.positionMode, Keys.panelWidth, Keys.panelHeight, Keys.rememberPanelSize,
                    GridPreferences.columnModeKey, GridPreferences.densityKey]
                + Self.colorOverrideKeys
        case .capture:
            return [Keys.pollingIntervalMs, Keys.captureImages, Keys.maxImageSizeMB, Keys.captureFiles, Keys.maxFileSizeMB,
                    Keys.captureSoundEnabled, Keys.captureSoundName, Keys.captureSoundID, Keys.captureSoundVolume,
                    Keys.ignoredBundleIDs, Capture.captureOnLaunch, Capture.typeBlocklist, Capture.sensitiveAutoClearSeconds,
                    Capture.autoClearDeletesHistory, Capture.pasteProfiles]
        case .ai:
            return [Keys.aiEnabled, Keys.aiProvider, Keys.aiModel, Keys.aiBaseURL, Keys.aiAzureAPIVersion,
                    Keys.aiAutoSuggestTitles, Keys.aiAgentAllowScripts, Keys.aiAgentAllowCodeExecution, Keys.aiAgentAllowWebSearch]
        case .intelligence:
            return [Keys.suggestionsEnabled, Keys.suggestionsLimit, Keys.suggestionsUseWindowText, Keys.suggestionsAutoOpen]
        case .integrations:
            return [Keys.onePasswordEnabled, Keys.onePasswordVault, Keys.onePasswordAutoClearClipboard,
                    Keys.onePasswordAutoClearDelaySecs, Keys.iCloudSyncEnabled, Keys.mcpEnabled, Keys.mcpPort]
        case .ocr: return [Capture.ocrLanguages]
        case .preview:
            return [PreviewColumnPreferences.enabledKey, PreviewColumnPreferences.widthKey, LinkPreviewPreferences.enabledKey,
                    LinkPreviewPreferences.allowKey, LinkPreviewPreferences.denyKey]
        case .snippets:
            return ["clippy.snippets.expansionEnabled", "clippy.snippets.triggerMode", "clippy.snippets.caseSensitive",
                    "clippy.snippets.excludedBundleIDs", "clippy.snippets.allowEnvPlaceholder"]
        case .semantic:
            return ["clippy.semantic.enabled", "clippy.semantic.autoFile.enabled", "clippy.semantic.autoFile.foundationRefinement"]
        case .automation:
            return [AutomationSettings.urlSchemeWritesKey, AutomationSettings.spotlightIndexingKey]
        case .pasteStack, .security, .data, .editor, .scripts, .about: return []
        }
    }

    /// The per-token color override keys (all empty by default).
    static let colorOverrideKeys: [String] = [
        AppSettings.Keys.customPanelHex, AppSettings.Keys.customScrollBgHex, AppSettings.Keys.customCardSurfaceHex,
        AppSettings.Keys.customCardBorderHex, AppSettings.Keys.customHeaderHex, AppSettings.Keys.customFooterHex,
        AppSettings.Keys.customSidebarHex, AppSettings.Keys.customScrollbarHex, AppSettings.Keys.customTextPrimaryHex,
        AppSettings.Keys.customTextSecondaryHex, AppSettings.Keys.customAccentHex, AppSettings.Keys.customSuccessHex,
        AppSettings.Keys.customDangerHex,
    ]

    /// Keys reset by the pane, including obsolete storage that must never be re-imported.
    var resetKeys: [String] {
        self == .appearance ? keys + [AppSettings.Keys.clipColumns] : keys
    }

    /// Every key exportable through preferences export/import.
    static var allExportableKeys: Set<String> { Set(allCases.flatMap(\.keys)) }

    /// True when the pane offers "Reset this pane".
    var isResettable: Bool { !keys.isEmpty }
}

/// A labeled group of panes in the sidebar.
struct SettingsPaneSection: Identifiable {
    let title: String
    let panes: [SettingsPaneID]
    var id: String { title }

    /// Every pane appears in exactly one section, in sidebar order.
    static let all: [SettingsPaneSection] = [
        .init(title: "Essentials", panes: [.general, .appearance]),
        .init(title: "Capture & Paste", panes: [.capture, .pasteStack, .snippets, .preview, .editor, .ocr]),
        .init(title: "Intelligence", panes: [.ai, .intelligence, .semantic]),
        .init(title: "Privacy & Data", panes: [.security, .data]),
        .init(title: "Extend", panes: [.integrations, .automation, .scripts, .about]),
    ]
}

/// Builds the view for a pane.
enum SettingsPaneRegistry {
    /// The pane content. Panes owned by other areas are instantiated by name.
    @ViewBuilder
    static func view(for pane: SettingsPaneID) -> some View {
        switch pane {
        case .general: GeneralSettingsTab()
        case .appearance: AppearanceSettingsTab()
        case .capture: CaptureSettingsTab()
        case .ai: AISettingsTab()
        case .preview: PreviewSettingsPane()
        case .pasteStack: PasteStackSettingsPane()
        case .snippets: SnippetsSettingsPane()
        case .semantic: SemanticSettingsPane()
        case .automation: AutomationSettingsPane()
        case .intelligence: IntelligenceSettingsPane()
        case .security: SecuritySettingsPane()
        case .data: DataSettingsPane()
        case .integrations: IntegrationsSettingsTab()
        case .scripts: ScriptsView()
        case .ocr: OCRSettingsPane()
        case .editor: EditorSettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}
