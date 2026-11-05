import Foundation
import SwiftUI
import Observation

/// Every user-facing knob, persisted in UserDefaults. Views bind to this
/// directly; services read it on each use so changes apply immediately.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // Observation: `@Observable` tracks every stored property below that is not
    // marked `@ObservationIgnored`. The `@AppDefault` / `@GatedPublished`
    // properties carry a property wrapper, which the macro cannot also wrap, so
    // they are `@ObservationIgnored` and report their own reads and writes to the
    // registrar (see ObservationNotifying in AppDefault.swift).

    let defaults: UserDefaults

    // MARK: - Converted properties (@AppDefault)
    //
    // Each line replaces a stored var + didSet { defaults.set(...) } block.
    // Key strings are passed as Keys.x so the byte-identical string constant
    // is preserved. Defaults match the values registered in init exactly.
    //
    // @AppDefault uses UserDefaults.standard directly. No test constructs
    // AppSettings with a custom UserDefaults (all tests use .shared), so
    // this does not break any test seam. See AppDefault.swift for details.

    @ObservationIgnored @AppDefault(Keys.positionMode, default: PanelPositionMode.caret)
    var positionMode: PanelPositionMode

    @ObservationIgnored @AppDefault(Keys.panelWidth, default: AppSettings.defaultPanelWidth)
    var panelWidth: Double

    @ObservationIgnored @AppDefault(Keys.panelHeight, default: AppSettings.defaultPanelHeight)
    var panelHeight: Double

    @ObservationIgnored @AppDefault(Keys.rememberPanelSize, default: true)
    var rememberPanelSize: Bool

    // pollingIntervalMs: kept as an observed stored property because ClipboardMonitor
    // tracks it to react live to polling-interval changes.
    var pollingIntervalMs: Double {
        didSet { defaults.set(pollingIntervalMs, forKey: Keys.pollingIntervalMs) }
    }

    @ObservationIgnored @AppDefault(Keys.maxHistoryItems, default: AppSettings.defaultMaxHistoryItems)
    var maxHistoryItems: Int

    @ObservationIgnored @AppDefault(Keys.movePastedItemToTop, default: false)
    var movePastedItemToTop: Bool

    @ObservationIgnored @AppDefault(Keys.pastePlainTextByDefault, default: false)
    var pastePlainTextByDefault: Bool

    @ObservationIgnored @AppDefault(Keys.ignoredBundleIDs, default: [String]())
    var ignoredBundleIDs: [String]

    @ObservationIgnored @AppDefault(Keys.appearanceMode, default: AppearanceMode.system)
    var appearanceMode: AppearanceMode

    @ObservationIgnored @AppDefault(Keys.accentTheme, default: AccentTheme.clippyAmber)
    var accentTheme: AccentTheme

    @ObservationIgnored @AppDefault(Keys.panelMaterial, default: PanelMaterialStyle.opaque)
    var panelMaterial: PanelMaterialStyle

    @ObservationIgnored @AppDefault(Keys.cardColorMode, default: CardColorMode.byApp)
    var cardColorMode: CardColorMode

    @ObservationIgnored @AppDefault(Keys.showAppIcons, default: true)
    var showAppIcons: Bool

    @ObservationIgnored @AppDefault(Keys.showSectionHeaders, default: true)
    var showSectionHeaders: Bool

    @ObservationIgnored @AppDefault(Keys.captureImages, default: true)
    private var managedCaptureImages: Bool

    var captureImages: Bool {
        get { managedCaptureImages }
        set {
            guard !Self.isForced(Keys.captureImages) else { return }
            managedCaptureImages = newValue
        }
    }

    @ObservationIgnored @AppDefault(Keys.maxImageSizeMB, default: 20)
    var maxImageSizeMB: Int

    /// When true, Clippy captures file URLs copied in Finder as file clips.
    @ObservationIgnored @AppDefault(Keys.captureFiles, default: true)
    private var managedCaptureFiles: Bool

    var captureFiles: Bool {
        get { managedCaptureFiles }
        set {
            guard !Self.isForced(Keys.captureFiles) else { return }
            managedCaptureFiles = newValue
        }
    }

    /// Largest file (in MB) whose actual bytes are copied into Clippy's local
    /// store. Files larger than this are kept as a path reference only. See the
    /// data-sensitivity note in docs: copied bytes are retained locally.
    @ObservationIgnored @AppDefault(Keys.maxFileSizeMB, default: 50)
    var maxFileSizeMB: Int

    /// Whether to play a sound after each successful clip save. Defaults to
    /// false so existing users hear no change until they opt in.
    @ObservationIgnored @AppDefault(Keys.captureSoundEnabled, default: false)
    var captureSoundEnabled: Bool

    /// Volume in 0-100 integer percent, matching the slider range.
    @ObservationIgnored @AppDefault(Keys.captureSoundVolume, default: 50)
    var captureSoundVolume: Int

    // MARK: - New appearance knobs

    /// Card rendering style: filled (opaque face), bordered (outline only), or plain.
    @ObservationIgnored @AppDefault(Keys.cardStyle, default: CardStyle.filled)
    var cardStyle: CardStyle

    /// Identity-color tint strength on cards, 0-20 percent. 0 = no tint.
    @ObservationIgnored @AppDefault(Keys.cardTintStrength, default: 8)
    var cardTintStrength: Int

    /// When true, card title and preview text use .primary instead of .secondary /
    /// subdued colors, improving contrast on both light and dark backgrounds.
    @ObservationIgnored @AppDefault(Keys.highContrastCardText, default: false)
    var highContrastCardText: Bool

    /// Number of columns in the clip list. 1 = single-column rows (default);
    /// 2-4 = card grid, filled left-to-right in reading order. Clamped 1...4.
    @ObservationIgnored @AppDefault(Keys.clipColumns, default: 1)
    var clipColumns: Int

    /// Panel UI font family. .systemDefault uses the system font.
    @ObservationIgnored @AppDefault(Keys.fontFamily, default: PanelFontFamily.systemDefault)
    var fontFamily: PanelFontFamily

    // MARK: - Theme

    /// Named theme preset. Drives the whole token table; see Theme.tokens().
    @ObservationIgnored @AppDefault(Keys.themePreset, default: ThemePreset.automatic)
    var themePreset: ThemePreset

    /// Whether the custom palette is a dark theme (affects scrollbar/appearance).
    @ObservationIgnored @AppDefault(Keys.customIsDark, default: false)
    var customIsDark: Bool

    // Per-token overrides. Each holds a single surface/text color the user has
    // pinned on top of whatever preset is active. An empty string means "no
    // override; use the preset's base value", so a fresh install looks exactly
    // like the chosen preset. Existing users who set colors under the old Custom
    // flow keep their non-empty hex and are unaffected. Theme.tokens() applies
    // them in one overlay pass; see applyOverrides there.

    @ObservationIgnored @AppDefault(Keys.customPanelHex, default: "")
    var customPanelHex: String

    @ObservationIgnored @AppDefault(Keys.customScrollBgHex, default: "")
    var customScrollBgHex: String

    @ObservationIgnored @AppDefault(Keys.customCardSurfaceHex, default: "")
    var customCardSurfaceHex: String

    @ObservationIgnored @AppDefault(Keys.customCardBorderHex, default: "")
    var customCardBorderHex: String

    @ObservationIgnored @AppDefault(Keys.customHeaderHex, default: "")
    var customHeaderHex: String

    @ObservationIgnored @AppDefault(Keys.customFooterHex, default: "")
    var customFooterHex: String

    @ObservationIgnored @AppDefault(Keys.customSidebarHex, default: "")
    var customSidebarHex: String

    @ObservationIgnored @AppDefault(Keys.customScrollbarHex, default: "")
    var customScrollbarHex: String

    @ObservationIgnored @AppDefault(Keys.customTextPrimaryHex, default: "")
    var customTextPrimaryHex: String

    @ObservationIgnored @AppDefault(Keys.customTextSecondaryHex, default: "")
    var customTextSecondaryHex: String

    @ObservationIgnored @AppDefault(Keys.customAccentHex, default: "")
    var customAccentHex: String

    @ObservationIgnored @AppDefault(Keys.customSuccessHex, default: "")
    var customSuccessHex: String

    @ObservationIgnored @AppDefault(Keys.customDangerHex, default: "")
    var customDangerHex: String

    // MARK: - AI / LLM integration

    /// Managed-preference note: the properties below that wrap a private
    /// `managed*` store are SEC-01 lockable. When IT forces the key the setter
    /// is a no-op; see AppSettings+Managed.swift.
    ///
    /// Master switch for all AI/agentic features. Off by default; nothing reaches
    /// a provider until the user opts in and configures one.
    @ObservationIgnored @AppDefault(Keys.aiEnabled, default: false)
    private var managedAiEnabled: Bool

    var aiEnabled: Bool {
        get { managedAiEnabled }
        set {
            guard !Self.isForced(Keys.aiEnabled) else { return }
            managedAiEnabled = newValue
        }
    }

    /// Model id / Azure deployment name. Empty falls back to the provider default.
    @ObservationIgnored @AppDefault(Keys.aiModel, default: "")
    var aiModel: String

    /// Endpoint base URL. Empty falls back to the provider default.
    @ObservationIgnored @AppDefault(Keys.aiBaseURL, default: "")
    private var managedAiBaseURL: String

    var aiBaseURL: String {
        get { managedAiBaseURL }
        set {
            guard !Self.isForced(Keys.aiBaseURL) else { return }
            managedAiBaseURL = newValue
        }
    }

    /// Azure AI Foundry data-plane api-version.
    @ObservationIgnored @AppDefault(Keys.aiAzureAPIVersion, default: "2024-10-21")
    var aiAzureAPIVersion: String

    /// When on, newly captured clips get an AI-suggested title automatically
    /// (still reversible; the only auto-applied action).
    @ObservationIgnored @AppDefault(Keys.aiAutoSuggestTitles, default: false)
    private var managedAiAutoSuggestTitles: Bool

    var aiAutoSuggestTitles: Bool {
        get { managedAiAutoSuggestTitles }
        set {
            guard !Self.isForced(Keys.aiAutoSuggestTitles) else { return }
            managedAiAutoSuggestTitles = newValue
        }
    }

    /// When on, the AI assistant may run saved scripts via the run_script tool.
    /// Off by default; user must explicitly opt in.
    @ObservationIgnored @AppDefault(Keys.aiAgentAllowScripts, default: false)
    private var managedAiAgentAllowScripts: Bool

    var aiAgentAllowScripts: Bool {
        get { managedAiAgentAllowScripts }
        set {
            guard !Self.isForced(Keys.aiAgentAllowScripts) else { return }
            managedAiAgentAllowScripts = newValue
        }
    }

    /// When on, the AI assistant may execute AI-generated code via the execute_code tool.
    /// Off by default; user must explicitly opt in.
    @ObservationIgnored @AppDefault(Keys.aiAgentAllowCodeExecution, default: false)
    private var managedAiAgentAllowCodeExecution: Bool

    var aiAgentAllowCodeExecution: Bool {
        get { managedAiAgentAllowCodeExecution }
        set {
            guard !Self.isForced(Keys.aiAgentAllowCodeExecution) else { return }
            managedAiAgentAllowCodeExecution = newValue
        }
    }

    /// When on, the AI assistant may search the web via the web_search tool.
    /// Off by default (SEC-01): the query string is sent to DuckDuckGo, which for a
    /// regulated firm must be an explicit opt-in (or an IT-forced value).
    @ObservationIgnored @AppDefault(Keys.aiAgentAllowWebSearch, default: false)
    private var managedAiAgentAllowWebSearch: Bool

    var aiAgentAllowWebSearch: Bool {
        get { managedAiAgentAllowWebSearch }
        set {
            guard !Self.isForced(Keys.aiAgentAllowWebSearch) else { return }
            managedAiAgentAllowWebSearch = newValue
        }
    }

    // MARK: - 1Password

    /// Show the 1Password vault as a sidebar category. Off by default; requires
    /// the `op` CLI installed and signed in.
    @ObservationIgnored @AppDefault(Keys.onePasswordEnabled, default: false)
    var onePasswordEnabled: Bool

    /// The vault Clippy reads from and creates secrets in.
    @ObservationIgnored @AppDefault(Keys.onePasswordVault, default: "Clippy")
    var onePasswordVault: String

    /// When true, the clipboard is cleared N seconds after copying a 1Password
    /// secret (only if the pasteboard still holds that exact write).
    @ObservationIgnored @AppDefault(Keys.onePasswordAutoClearClipboard, default: true)
    private var managedOnePasswordAutoClearClipboard: Bool

    var onePasswordAutoClearClipboard: Bool {
        get { managedOnePasswordAutoClearClipboard }
        set {
            guard !Self.isForced(Keys.onePasswordAutoClearClipboard) else { return }
            managedOnePasswordAutoClearClipboard = newValue
        }
    }

    // MARK: - iCloud sync

    /// Mirror clips and categories to the user's private CloudKit database.
    @ObservationIgnored @AppDefault(Keys.iCloudSyncEnabled, default: false)
    private var managedICloudSyncEnabled: Bool

    var iCloudSyncEnabled: Bool {
        get { managedICloudSyncEnabled }
        set {
            guard !Self.isForced(Keys.iCloudSyncEnabled) else { return }
            managedICloudSyncEnabled = newValue
        }
    }

    /// When true, clicking a clip card only copies it to the clipboard. When
    /// false (default), clicking also pastes into the frontmost app.
    @ObservationIgnored @AppDefault(Keys.clickCopyOnly, default: false)
    var clickCopyOnly: Bool

    /// Per-character pacing for the "send keystrokes" action.
    @ObservationIgnored @AppDefault(Keys.keystrokeSpeed, default: KeystrokeSpeed.balanced)
    var keystrokeSpeed: KeystrokeSpeed

    // mcpEnabled: observed through GatedPublished so McpServerController can
    // track it to start/stop the server live on toggle, while an
    // MDM-forced key (SEC-01) rejects writes without notifying observers.
    @ObservationIgnored @GatedPublished(key: Keys.mcpEnabled,
                    initial: UserDefaults.standard.bool(forKey: Keys.mcpEnabled))
    var mcpEnabled: Bool

    // MARK: - Panel behavior

    /// When true, the panel hides if the user clicks another app (key resignation).
    /// Default false: preserves the existing always-persistent behavior so existing
    /// users see no change until they opt in.
    @ObservationIgnored @AppDefault(Keys.hideOnClickAway, default: false)
    var hideOnClickAway: Bool

    /// When true, more than one category can be selected at once in the panel.
    /// Default false: preserves the existing single-selection behavior so existing
    /// users see no change until they opt in.
    @ObservationIgnored @AppDefault(Keys.allowMultipleCategories, default: false)
    var allowMultipleCategories: Bool

    /// When true, the panel hides after a paste or keystroke action (current behavior).
    /// Default true: preserves existing behavior; set false to keep the panel open
    /// for rapid multi-paste workflows.
    @ObservationIgnored @AppDefault(Keys.hideAfterPaste, default: true)
    var hideAfterPaste: Bool

    /// When true, pressing Escape closes the panel (current behavior).
    /// Default true: preserves existing behavior.
    @ObservationIgnored @AppDefault(Keys.hideOnEscape, default: true)
    var hideOnEscape: Bool

    /// Window level and floating behavior for the panel. alwaysOnTop is the
    /// current default (.statusBar level); other values trade visibility for
    /// less intrusion into normal app z-order.
    @ObservationIgnored @AppDefault(Keys.panelFloatLevel, default: PanelFloatLevel.alwaysOnTop)
    var panelFloatLevel: PanelFloatLevel

    /// When true, suppresses all auto-hide triggers (click-away, after-paste,
    /// Escape) so the panel stays open regardless of other behavior settings.
    /// Intended as a quick "pin" override, default false.
    @ObservationIgnored @AppDefault(Keys.panelPinned, default: false)
    var panelPinned: Bool

    // MARK: - Logging

    /// Minimum severity that ClippyLog emits to both sinks. Stored as the
    /// LogLevel rawValue (Int) via the RawRepresentable @AppDefault init.
    /// The SettingsView picker pushes changes to ClippyLog.threshold via
    /// .onChange; init seeds it once at startup. ClippyLog cannot read this
    /// itself without a Support->UI dependency cycle, so AppSettings is the
    /// one writer of the threshold.
    @ObservationIgnored @AppDefault(Keys.logLevel, default: ClippyLog.LogLevel.info)
    var logLevel: ClippyLog.LogLevel

    // MARK: - Smart Suggestions

    /// Master switch for Smart Suggestions. Off by default; nothing reads the
    /// frontmost app's context until the user opts in.
    @ObservationIgnored @AppDefault(Keys.suggestionsEnabled, default: false)
    private var managedSuggestionsEnabled: Bool

    var suggestionsEnabled: Bool {
        get { managedSuggestionsEnabled }
        set {
            guard !Self.isForced(Keys.suggestionsEnabled) else { return }
            managedSuggestionsEnabled = newValue
        }
    }

    /// When false, only the app name and window title feed the ranking; the
    /// focused field's text is never read.
    @ObservationIgnored @AppDefault(Keys.suggestionsUseWindowText, default: true)
    private var managedSuggestionsUseWindowText: Bool

    var suggestionsUseWindowText: Bool {
        get { managedSuggestionsUseWindowText }
        set {
            guard !Self.isForced(Keys.suggestionsUseWindowText) else { return }
            managedSuggestionsUseWindowText = newValue
        }
    }

    /// Open the Suggestions pane automatically when the panel shows and context is available.
    @ObservationIgnored @AppDefault(Keys.suggestionsAutoOpen, default: false)
    var suggestionsAutoOpen: Bool

    // MARK: - Properties kept as observed stored vars (clamping or migration logic in init)
    //
    // These cannot be collapsed into @AppDefault because their init reads more
    // than a plain UserDefaults fetch: they clamp to a valid range or run a
    // migration. The stored var + didSet pattern is intentionally kept here.

    /// Base font size in points (11-16). Clamped in init; 0 means key never written.
    var fontSizeBase: Int {
        didSet { defaults.set(fontSizeBase, forKey: Keys.fontSizeBase) }
    }

    /// Panel translucency, 0.30 (very see-through) to 1.0 (fully solid). At 1.0
    /// the panel is opaque with no blur, which is the fix for the washed-out
    /// look; below 1.0 a blur shows the desktop through the tinted background.
    /// Clamped in init to 0.3-1.0.
    var panelOpacity: Double {
        didSet { defaults.set(panelOpacity, forKey: Keys.panelOpacity) }
    }

    /// Stable identifier of the chosen capture sound. Init runs resolveSoundID()
    /// to migrate the legacy captureSoundName key written by older builds.
    var captureSoundID: String {
        didSet { defaults.set(captureSoundID, forKey: Keys.captureSoundID) }
    }

    /// Above this character count, "send keystrokes" asks for confirmation.
    /// Init guards stored > 0 to recover from a corrupt/missing entry.
    var keystrokeWarnThreshold: Int {
        didSet { defaults.set(keystrokeWarnThreshold, forKey: Keys.keystrokeWarnThreshold) }
    }

    /// Seconds to wait before auto-clearing a copied 1Password secret. Default 90.
    /// Clamped to 10-600 (stored value out of range falls back to 90). Lockable by
    /// managed preferences (SEC-01), so it goes through GatedPublished.
    @ObservationIgnored @GatedPublished(
        key: Keys.onePasswordAutoClearDelaySecs,
        initial: {
            let stored = UserDefaults.standard.integer(forKey: Keys.onePasswordAutoClearDelaySecs)
            return stored >= 10 && stored <= 600 ? stored : 90
        }(),
        sanitize: { min(600, max(10, $0)) }
    )
    var onePasswordAutoClearDelaySecs: Int

    /// Preferred localhost port for the bundled MCP HTTP server. Clamped in init
    /// to a valid user-space port (1024-65535).
    var mcpPort: Int {
        didSet {
            // Clamp at the setter, not just at init: a value typed into the
            // Settings port field at runtime must never reach the socket layer
            // out of range (UInt16(port) traps for >65535 or <0).
            let clamped = min(65535, max(1024, mcpPort))
            if clamped != mcpPort { mcpPort = clamped; return }
            defaults.set(mcpPort, forKey: Keys.mcpPort)
        }
    }

    /// How many suggestions to show. Default 8; clamped to 3-20 at init and in the setter.
    var suggestionsLimit: Int {
        didSet {
            let clamped = min(20, max(3, suggestionsLimit))
            if clamped != suggestionsLimit { suggestionsLimit = clamped; return }
            defaults.set(suggestionsLimit, forKey: Keys.suggestionsLimit)
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
    @ObservationIgnored var cachedTokensStorage: ThemeTokens?
    @ObservationIgnored var cachedTokenSignatureStorage: Int = 0

    /// Whether the window hosting the design system currently renders dark, as
    /// reported by its SwiftUI color scheme. nil until a host reports. Not
    /// persisted; "Match system" themes resolve from it so they flip live.
    @ObservationIgnored private var hostColorSchemeStorage: Bool?

    var hostColorSchemeIsDark: Bool? {
        access(keyPath: \.hostColorSchemeIsDark)
        return hostColorSchemeStorage
    }

    /// Bumped when storage is rewritten behind the observed properties' backs
    /// (reset, import). `@AppDefault` reads depend on it, and views holding local
    /// copies of stored values watch it to re-read them.
    private(set) var storageRevision = 0

    /// Records the hosting window's scheme. Silent on purpose: it runs while a
    /// view body evaluates, where mutating observed state is not allowed; the
    /// host calls `hostColorSchemeDidChange()` from `onChange` so observers re-render.
    func hostColorSchemeChanged(isDark: Bool) {
        hostColorSchemeStorage = isDark
    }

    /// Tells observers of `hostColorSchemeIsDark` (and therefore `theme`) to re-render.
    func hostColorSchemeDidChange() {
        withMutation(keyPath: \.hostColorSchemeIsDark) {}
    }

    /// Announces that persisted values were rewritten in bulk.
    func announceStorageReloaded() {
        storageRevision &+= 1
    }

    // MARK: - Init

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Register all defaults so UserDefaults.standard returns correct values
        // before the user has touched a setting. @AppDefault reads .standard
        // directly, so this must happen before any wrapper is accessed.
        Self.registerDefaults(defaults)
        Self.lowerBumpedPanelSize(defaults)

        // Init loads only the properties that cannot be expressed as a plain
        // @AppDefault read: those requiring range clamping or migration logic.
        // All other properties are read on-demand by the @AppDefault wrapper.

        pollingIntervalMs = defaults.double(forKey: Keys.pollingIntervalMs)
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
        mcpPort = {
            let stored = defaults.integer(forKey: Keys.mcpPort)
            return (stored >= 1024 && stored <= 65535) ? stored : 51764
        }()
        suggestionsLimit = {
            let stored = defaults.integer(forKey: Keys.suggestionsLimit)
            return stored >= 3 && stored <= 20 ? stored : 8
        }()

        // Seed the logger threshold from the stored level. @AppDefault reads
        // .standard, which is registered above, so logLevel is valid here.
        // The SettingsView picker keeps this in sync afterward via .onChange.
        ClippyLog.threshold = logLevel
    }
}

extension AppSettings: ObservationNotifying {}
