import Combine
import Foundation
import SwiftUI

enum PanelPositionMode: String, CaseIterable, Identifiable {
    case caret
    case mouse
    case lastPosition
    case screenCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .caret: return "At text cursor"
        case .mouse: return "At mouse pointer"
        case .lastPosition: return "Last position"
        case .screenCenter: return "Screen center"
        }
    }
}

/// Where the panel sits in the macOS window stack.
/// alwaysOnTop: .statusBar level + isFloatingPanel (current default, floats above every app window).
/// aboveNormalWindows: .floating level + isFloatingPanel (floats above normal windows, below status bar).
/// normalOrder: .normal level, not floating (respects app z-order, stays behind full-screen chrome).
enum PanelFloatLevel: String, CaseIterable, Identifiable {
    case alwaysOnTop
    case aboveNormalWindows
    case normalOrder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alwaysOnTop: return "Always on top"
        case .aboveNormalWindows: return "Above normal windows"
        case .normalOrder: return "Normal window order"
        }
    }
}

/// Per-character pacing for the "send keystrokes" action. Faster feels instant
/// but can drop characters in slow or remote targets; deliberate is the safest.
enum KeystrokeSpeed: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case deliberate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .deliberate: return "Deliberate"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Near-instant (~2ms/char). May drop characters in remote or sluggish apps."
        case .balanced: return "Reliable for everyday use (~6ms/char)."
        case .deliberate: return "Visibly typed (~20ms/char). Maximum compatibility."
        }
    }

    /// Delay between characters in microseconds, for usleep between key events.
    var perCharDelayMicros: useconds_t {
        switch self {
        case .fast: return 2_000
        case .balanced: return 6_000
        case .deliberate: return 20_000
        }
    }
}

/// Every user-facing knob, persisted in UserDefaults. Views bind to this
/// directly; services read it on each use so changes apply immediately.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // objectWillChange is left to the compiler. With @Published properties
    // present, Swift synthesizes it as ObservableObjectPublisher AND wires
    // every @Published willSet to it. A hand-rolled publisher here would
    // suppress that auto-wiring, so @Published settings (pollingIntervalMs,
    // mcpEnabled, fontSizeBase, panelOpacity, captureSoundID, ...) would
    // mutate without notifying any view -- the "nothing can be changed"
    // regression. The @AppDefault subscript's
    // `ObjectWillChangePublisher == ObservableObjectPublisher` constraint
    // still holds against the synthesized publisher, so its explicit
    // `objectWillChange.send()` keeps working.

    private enum Keys {
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
    }

    private let defaults: UserDefaults

    // MARK: - Converted properties (@AppDefault)
    //
    // Each line replaces a @Published var + didSet { defaults.set(...) } block.
    // Key strings are passed as Keys.x so the byte-identical string constant
    // is preserved. Defaults match the values registered in init exactly.
    //
    // @AppDefault uses UserDefaults.standard directly. No test constructs
    // AppSettings with a custom UserDefaults (all tests use .shared), so
    // this does not break any test seam. See AppDefault.swift for details.

    @AppDefault(Keys.positionMode, default: PanelPositionMode.caret)
    var positionMode: PanelPositionMode

    @AppDefault(Keys.panelWidth, default: 640.0)
    var panelWidth: Double

    @AppDefault(Keys.panelHeight, default: 480.0)
    var panelHeight: Double

    @AppDefault(Keys.rememberPanelSize, default: true)
    var rememberPanelSize: Bool

    // pollingIntervalMs: kept @Published because ClipboardMonitor subscribes
    // via $pollingIntervalMs to react live to polling-interval changes.
    @Published var pollingIntervalMs: Double {
        didSet { defaults.set(pollingIntervalMs, forKey: Keys.pollingIntervalMs) }
    }

    @AppDefault(Keys.maxHistoryItems, default: 500)
    var maxHistoryItems: Int

    @AppDefault(Keys.movePastedItemToTop, default: false)
    var movePastedItemToTop: Bool

    @AppDefault(Keys.pastePlainTextByDefault, default: false)
    var pastePlainTextByDefault: Bool

    @AppDefault(Keys.ignoredBundleIDs, default: [String]())
    var ignoredBundleIDs: [String]

    @AppDefault(Keys.appearanceMode, default: AppearanceMode.system)
    var appearanceMode: AppearanceMode

    @AppDefault(Keys.accentTheme, default: AccentTheme.clippyAmber)
    var accentTheme: AccentTheme

    @AppDefault(Keys.panelMaterial, default: PanelMaterialStyle.opaque)
    var panelMaterial: PanelMaterialStyle

    @AppDefault(Keys.cardColorMode, default: CardColorMode.byApp)
    var cardColorMode: CardColorMode

    @AppDefault(Keys.showAppIcons, default: true)
    var showAppIcons: Bool

    @AppDefault(Keys.showSectionHeaders, default: true)
    var showSectionHeaders: Bool

    @AppDefault(Keys.captureImages, default: true)
    var captureImages: Bool

    @AppDefault(Keys.maxImageSizeMB, default: 20)
    var maxImageSizeMB: Int

    /// When true, Clippy captures file URLs copied in Finder as file clips.
    @AppDefault(Keys.captureFiles, default: true)
    var captureFiles: Bool

    /// Largest file (in MB) whose actual bytes are copied into Clippy's local
    /// store. Files larger than this are kept as a path reference only. See the
    /// data-sensitivity note in docs: copied bytes are retained locally.
    @AppDefault(Keys.maxFileSizeMB, default: 50)
    var maxFileSizeMB: Int

    /// Whether to play a sound after each successful clip save. Defaults to
    /// false so existing users hear no change until they opt in.
    @AppDefault(Keys.captureSoundEnabled, default: false)
    var captureSoundEnabled: Bool

    /// Volume in 0-100 integer percent, matching the slider range.
    @AppDefault(Keys.captureSoundVolume, default: 50)
    var captureSoundVolume: Int

    // MARK: - New appearance knobs

    /// Card rendering style: filled (opaque face), bordered (outline only), or plain.
    @AppDefault(Keys.cardStyle, default: CardStyle.filled)
    var cardStyle: CardStyle

    /// Identity-color tint strength on cards, 0-20 percent. 0 = no tint.
    @AppDefault(Keys.cardTintStrength, default: 8)
    var cardTintStrength: Int

    /// When true, card title and preview text use .primary instead of .secondary /
    /// subdued colors, improving contrast on both light and dark backgrounds.
    @AppDefault(Keys.highContrastCardText, default: false)
    var highContrastCardText: Bool

    /// Number of columns in the clip list. 1 = single-column rows (default);
    /// 2-4 = card grid, filled left-to-right in reading order. Clamped 1...4.
    @AppDefault(Keys.clipColumns, default: 1)
    var clipColumns: Int

    /// Panel UI font family. .systemDefault uses the system font.
    @AppDefault(Keys.fontFamily, default: PanelFontFamily.systemDefault)
    var fontFamily: PanelFontFamily

    // MARK: - Theme

    /// Named theme preset. Drives the whole token table; see Theme.tokens().
    @AppDefault(Keys.themePreset, default: ThemePreset.cleanLight)
    var themePreset: ThemePreset

    /// Whether the custom palette is a dark theme (affects scrollbar/appearance).
    @AppDefault(Keys.customIsDark, default: false)
    var customIsDark: Bool

    // Per-token overrides. Each holds a single surface/text color the user has
    // pinned on top of whatever preset is active. An empty string means "no
    // override; use the preset's base value", so a fresh install looks exactly
    // like the chosen preset. Existing users who set colors under the old Custom
    // flow keep their non-empty hex and are unaffected. Theme.tokens() applies
    // them in one overlay pass; see applyOverrides there.

    @AppDefault(Keys.customPanelHex, default: "")
    var customPanelHex: String

    @AppDefault(Keys.customScrollBgHex, default: "")
    var customScrollBgHex: String

    @AppDefault(Keys.customCardSurfaceHex, default: "")
    var customCardSurfaceHex: String

    @AppDefault(Keys.customCardBorderHex, default: "")
    var customCardBorderHex: String

    @AppDefault(Keys.customHeaderHex, default: "")
    var customHeaderHex: String

    @AppDefault(Keys.customFooterHex, default: "")
    var customFooterHex: String

    @AppDefault(Keys.customSidebarHex, default: "")
    var customSidebarHex: String

    @AppDefault(Keys.customScrollbarHex, default: "")
    var customScrollbarHex: String

    @AppDefault(Keys.customTextPrimaryHex, default: "")
    var customTextPrimaryHex: String

    @AppDefault(Keys.customTextSecondaryHex, default: "")
    var customTextSecondaryHex: String

    @AppDefault(Keys.customAccentHex, default: "")
    var customAccentHex: String

    @AppDefault(Keys.customSuccessHex, default: "")
    var customSuccessHex: String

    @AppDefault(Keys.customDangerHex, default: "")
    var customDangerHex: String

    // MARK: - AI / LLM integration

    /// Master switch for all AI/agentic features. Off by default; nothing reaches
    /// a provider until the user opts in and configures one.
    @AppDefault(Keys.aiEnabled, default: false)
    var aiEnabled: Bool

    /// Which backend to talk to. The API key (when needed) lives in the keychain,
    /// never here.
    @AppDefault(Keys.aiProvider, default: AIProviderKind.ollama)
    var aiProvider: AIProviderKind

    /// Model id / Azure deployment name. Empty falls back to the provider default.
    @AppDefault(Keys.aiModel, default: "")
    var aiModel: String

    /// Endpoint base URL. Empty falls back to the provider default.
    @AppDefault(Keys.aiBaseURL, default: "")
    var aiBaseURL: String

    /// Azure AI Foundry data-plane api-version.
    @AppDefault(Keys.aiAzureAPIVersion, default: "2024-10-21")
    var aiAzureAPIVersion: String

    /// When on, newly captured clips get an AI-suggested title automatically
    /// (still reversible; the only auto-applied action).
    @AppDefault(Keys.aiAutoSuggestTitles, default: false)
    var aiAutoSuggestTitles: Bool

    /// When on, the AI assistant may run saved scripts via the run_script tool.
    /// Off by default; user must explicitly opt in.
    @AppDefault(Keys.aiAgentAllowScripts, default: false)
    var aiAgentAllowScripts: Bool

    /// When on, the AI assistant may execute AI-generated code via the execute_code tool.
    /// Off by default; user must explicitly opt in.
    @AppDefault(Keys.aiAgentAllowCodeExecution, default: false)
    var aiAgentAllowCodeExecution: Bool

    /// When on, the AI assistant may search the web via the web_search tool.
    /// On by default: it is read-only and the most useful agent capability, but
    /// note the query string is sent to DuckDuckGo, so it stays user-toggleable.
    @AppDefault(Keys.aiAgentAllowWebSearch, default: true)
    var aiAgentAllowWebSearch: Bool

    // MARK: - 1Password

    /// Show the 1Password vault as a sidebar category. Off by default; requires
    /// the `op` CLI installed and signed in.
    @AppDefault(Keys.onePasswordEnabled, default: false)
    var onePasswordEnabled: Bool

    /// The vault Clippy reads from and creates secrets in.
    @AppDefault(Keys.onePasswordVault, default: "Clippy")
    var onePasswordVault: String

    /// When true, the clipboard is cleared N seconds after copying a 1Password
    /// secret (only if the pasteboard still holds that exact write).
    @AppDefault(Keys.onePasswordAutoClearClipboard, default: true)
    var onePasswordAutoClearClipboard: Bool

    // MARK: - iCloud sync

    /// Mirror clips and categories to the user's private CloudKit database.
    @AppDefault(Keys.iCloudSyncEnabled, default: false)
    var iCloudSyncEnabled: Bool

    /// When true, clicking a clip card only copies it to the clipboard. When
    /// false (default), clicking also pastes into the frontmost app.
    @AppDefault(Keys.clickCopyOnly, default: false)
    var clickCopyOnly: Bool

    /// Per-character pacing for the "send keystrokes" action.
    @AppDefault(Keys.keystrokeSpeed, default: KeystrokeSpeed.balanced)
    var keystrokeSpeed: KeystrokeSpeed

    // mcpEnabled: kept @Published because McpServerController subscribes via
    // $mcpEnabled to start/stop the server live on toggle.
    @Published var mcpEnabled: Bool {
        didSet { defaults.set(mcpEnabled, forKey: Keys.mcpEnabled) }
    }

    // MARK: - Panel behavior

    /// When true, the panel hides if the user clicks another app (key resignation).
    /// Default false: preserves the existing always-persistent behavior so existing
    /// users see no change until they opt in.
    @AppDefault(Keys.hideOnClickAway, default: false)
    var hideOnClickAway: Bool

    /// When true, more than one category can be selected at once in the panel.
    /// Default false: preserves the existing single-selection behavior so existing
    /// users see no change until they opt in.
    @AppDefault(Keys.allowMultipleCategories, default: false)
    var allowMultipleCategories: Bool

    /// When true, the panel hides after a paste or keystroke action (current behavior).
    /// Default true: preserves existing behavior; set false to keep the panel open
    /// for rapid multi-paste workflows.
    @AppDefault(Keys.hideAfterPaste, default: true)
    var hideAfterPaste: Bool

    /// When true, pressing Escape closes the panel (current behavior).
    /// Default true: preserves existing behavior.
    @AppDefault(Keys.hideOnEscape, default: true)
    var hideOnEscape: Bool

    /// Window level and floating behavior for the panel. alwaysOnTop is the
    /// current default (.statusBar level); other values trade visibility for
    /// less intrusion into normal app z-order.
    @AppDefault(Keys.panelFloatLevel, default: PanelFloatLevel.alwaysOnTop)
    var panelFloatLevel: PanelFloatLevel

    /// When true, suppresses all auto-hide triggers (click-away, after-paste,
    /// Escape) so the panel stays open regardless of other behavior settings.
    /// Intended as a quick "pin" override, default false.
    @AppDefault(Keys.panelPinned, default: false)
    var panelPinned: Bool

    // MARK: - Logging

    /// Minimum severity that ClippyLog emits to both sinks. Stored as the
    /// LogLevel rawValue (Int) via the RawRepresentable @AppDefault init.
    /// The SettingsView picker pushes changes to ClippyLog.threshold via
    /// .onChange; init seeds it once at startup. ClippyLog cannot read this
    /// itself without a Support->UI dependency cycle, so AppSettings is the
    /// one writer of the threshold.
    @AppDefault(Keys.logLevel, default: ClippyLog.LogLevel.info)
    var logLevel: ClippyLog.LogLevel

    // MARK: - Properties kept as @Published (clamping or migration logic in init)
    //
    // These cannot be collapsed into @AppDefault because their init reads more
    // than a plain UserDefaults fetch: they clamp to a valid range or run a
    // migration. The @Published + didSet pattern is intentionally kept here.

    /// Base font size in points (11-16). Clamped in init; 0 means key never written.
    @Published var fontSizeBase: Int {
        didSet { defaults.set(fontSizeBase, forKey: Keys.fontSizeBase) }
    }

    /// Panel translucency, 0.30 (very see-through) to 1.0 (fully solid). At 1.0
    /// the panel is opaque with no blur, which is the fix for the washed-out
    /// look; below 1.0 a blur shows the desktop through the tinted background.
    /// Clamped in init to 0.3-1.0.
    @Published var panelOpacity: Double {
        didSet { defaults.set(panelOpacity, forKey: Keys.panelOpacity) }
    }

    /// Stable identifier of the chosen capture sound. Init runs resolveSoundID()
    /// to migrate the legacy captureSoundName key written by older builds.
    @Published var captureSoundID: String {
        didSet { defaults.set(captureSoundID, forKey: Keys.captureSoundID) }
    }

    /// Above this character count, "send keystrokes" asks for confirmation.
    /// Init guards stored > 0 to recover from a corrupt/missing entry.
    @Published var keystrokeWarnThreshold: Int {
        didSet { defaults.set(keystrokeWarnThreshold, forKey: Keys.keystrokeWarnThreshold) }
    }

    /// Seconds to wait before auto-clearing a copied 1Password secret. Default 90.
    /// Init clamps to 10-600.
    @Published var onePasswordAutoClearDelaySecs: Int {
        didSet { defaults.set(onePasswordAutoClearDelaySecs, forKey: Keys.onePasswordAutoClearDelaySecs) }
    }

    /// Preferred localhost port for the bundled MCP HTTP server. Clamped in init
    /// to a valid user-space port (1024-65535).
    @Published var mcpPort: Int {
        didSet {
            // Clamp at the setter, not just at init: a value typed into the
            // Settings port field at runtime must never reach the socket layer
            // out of range (UInt16(port) traps for >65535 or <0).
            let clamped = min(65535, max(1024, mcpPort))
            if clamped != mcpPort { mcpPort = clamped; return }
            defaults.set(mcpPort, forKey: Keys.mcpPort)
        }
    }

    // MARK: - Computed properties (not persisted directly)

    /// The resolved token table for the active theme. Views read this.
    ///
    /// Memoized: Theme.tokens(self) re-parses up to 13 custom-hex overrides on
    /// every call, and views read `theme` many times per render across hundreds
    /// of cards. The cache recomputes only when a signature of the inputs
    /// changes, so a steady-state render pays the parse cost once. Cache state
    /// lives on the instance; AppSettings is a singleton, so this is safe.
    private var _cachedTokens: ThemeTokens?
    private var _cachedTokenSignature: Int = 0

    var theme: ThemeTokens {
        let signature = tokenSignature
        if let cached = _cachedTokens, signature == _cachedTokenSignature {
            return cached
        }
        let resolved = Theme.tokens(self)
        _cachedTokens = resolved
        _cachedTokenSignature = signature
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
        return hasher.finalize()
    }

    var accentColor: Color { accentTheme.color }

    /// Where the panel was last closed, for the "last position" mode.
    var lastPanelOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.lastPanelX) != nil else { return nil }
            return CGPoint(
                x: defaults.double(forKey: Keys.lastPanelX),
                y: defaults.double(forKey: Keys.lastPanelY)
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.lastPanelX)
                defaults.removeObject(forKey: Keys.lastPanelY)
                return
            }
            defaults.set(newValue.x, forKey: Keys.lastPanelX)
            defaults.set(newValue.y, forKey: Keys.lastPanelY)
        }
    }

    // MARK: - Methods

    /// Clear every per-token override so the app falls back to the selected
    /// preset's base colors. Used by the "Reset all" affordance.
    func clearColorOverrides() {
        customPanelHex = ""
        customScrollBgHex = ""
        customCardSurfaceHex = ""
        customCardBorderHex = ""
        customHeaderHex = ""
        customFooterHex = ""
        customSidebarHex = ""
        customScrollbarHex = ""
        customTextPrimaryHex = ""
        customTextSecondaryHex = ""
        customAccentHex = ""
        customSuccessHex = ""
        customDangerHex = ""
    }

    /// Reset every setting to its registered default. Audit finding: the only
    /// global reset was clearColorOverrides. This wipes all stored keys so the
    /// @AppDefault wrappers fall back to their declared defaults, then re-applies
    /// the same clamping/migration the init does for the @Published properties.
    /// The theme's base colors, AI config, capture knobs, hotkeys, and behavior
    /// toggles all return to their out-of-box values. Does not touch the
    /// keychain (API keys) or the clip database.
    func resetAllToDefaults() {
        // Wipe every persisted settings key. @AppDefault reads live from
        // UserDefaults, so removing a key makes its wrapper return the declared
        // default on the next access without needing an explicit assignment.
        let allKeys: [String] = [
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
            Keys.hideOnClickAway, Keys.allowMultipleCategories, Keys.hideAfterPaste,
            Keys.hideOnEscape, Keys.panelFloatLevel, Keys.panelPinned, Keys.clipColumns,
            Keys.captureFiles, Keys.maxFileSizeMB, Keys.logLevel,
        ]
        for key in allKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }

        // @Published properties live in instance memory, not UserDefaults, so
        // removing keys is not enough: reset them to their defaults explicitly.
        // Each assignment fires objectWillChange so bound views re-render.
        pollingIntervalMs = 200.0
        mcpEnabled = false
        fontSizeBase = 13
        panelOpacity = 1.0
        captureSoundID = SoundCatalog.defaultID
        keystrokeWarnThreshold = 2000
        onePasswordAutoClearDelaySecs = 90
        mcpPort = 51764

        // Re-seed the logger threshold from the reset value.
        ClippyLog.threshold = logLevel

        // Fire one consolidated change so views bound to @AppDefault properties
        // (which did not go through their wrapper setter) re-read UserDefaults.
        // @AppDefault reads live from UserDefaults, so after the key removals
        // above they will return their declared defaultValue on the next access.
        objectWillChange.send()
    }

    // MARK: - Init

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Register all defaults so UserDefaults.standard returns correct
        // values even before the user has ever touched a setting. @AppDefault
        // reads .standard directly, so registration must happen before any
        // @AppDefault wrapper is accessed.
        defaults.register(defaults: [
            Keys.positionMode: PanelPositionMode.caret.rawValue,
            Keys.panelWidth: 640.0,
            Keys.panelHeight: 480.0,
            Keys.rememberPanelSize: true,
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
            // Clean Light is the default look; it fixes the washed-out grey.
            Keys.themePreset: ThemePreset.cleanLight.rawValue,
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
            Keys.aiProvider: AIProviderKind.ollama.rawValue,
            Keys.aiModel: "",
            Keys.aiBaseURL: "",
            Keys.aiAzureAPIVersion: "2024-10-21",
            Keys.aiAutoSuggestTitles: false,
            Keys.aiAgentAllowScripts: false,
            Keys.aiAgentAllowCodeExecution: false,
            Keys.aiAgentAllowWebSearch: true,
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
            // Panel behavior: all defaults preserve the pre-existing behavior exactly.
            Keys.hideOnClickAway: false,
            Keys.allowMultipleCategories: false,
            Keys.hideAfterPaste: true,
            Keys.hideOnEscape: true,
            Keys.panelFloatLevel: PanelFloatLevel.alwaysOnTop.rawValue,
            Keys.panelPinned: false,
            Keys.logLevel: ClippyLog.LogLevel.info.rawValue,
        ])

        // Init loads only the properties that cannot be expressed as a plain
        // @AppDefault read: those requiring range clamping or migration logic.
        // All other properties are read on-demand by the @AppDefault wrapper.

        pollingIntervalMs = defaults.double(forKey: Keys.pollingIntervalMs)
        mcpEnabled = defaults.bool(forKey: Keys.mcpEnabled)
        fontSizeBase = {
            let stored = defaults.integer(forKey: Keys.fontSizeBase)
            // Clamp to valid range; 0 means the key was never written (integer returns 0).
            return stored >= 11 && stored <= 16 ? stored : 13
        }()
        panelOpacity = {
            let stored = defaults.double(forKey: Keys.panelOpacity)
            return stored >= 0.3 && stored <= 1.0 ? stored : 1.0
        }()
        captureSoundID = Self.resolveSoundID(defaults)
        keystrokeWarnThreshold = {
            let stored = defaults.integer(forKey: Keys.keystrokeWarnThreshold)
            return stored > 0 ? stored : 2000
        }()
        onePasswordAutoClearDelaySecs = {
            let stored = defaults.integer(forKey: Keys.onePasswordAutoClearDelaySecs)
            return stored >= 10 && stored <= 600 ? stored : 90
        }()
        mcpPort = {
            let stored = defaults.integer(forKey: Keys.mcpPort)
            return (stored >= 1024 && stored <= 65535) ? stored : 51764
        }()

        // Seed the logger threshold from the stored level. @AppDefault reads
        // .standard, which is registered above, so logLevel is valid here.
        // The SettingsView picker keeps this in sync afterward via .onChange.
        ClippyLog.threshold = logLevel
    }

    /// Resolve the stored sound id, migrating the legacy classic-enum key the
    /// previous build wrote ("captureSoundName" = "Tink", "Pop", ...).
    private static func resolveSoundID(_ defaults: UserDefaults) -> String {
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
