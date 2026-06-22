import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The settings window. A System-Settings-style sidebar (a fixed list of
/// sections with colored icon tiles) plus a detail pane, themed to match Clippy.
/// Built explicitly rather than with TabView, whose macOS 15 default collapses a
/// multi-tab window into a navigation sidebar with an overflow control.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: SettingsSection = SettingsSection(
        rawValue: ProcessInfo.processInfo.environment["CLIPPY_SETTINGS_SECTION"] ?? "") ?? .general

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 780, minHeight: 580)
        .tint(tokens.accent)
        // Track the theme's light/dark appearance and accent so the whole app,
        // not just the panel, follows the theme.
        .background(WindowAppearanceApplier(appearance: Theme.nsAppearance(settings)))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { sidebarRow($0) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 214, maxWidth: 214)
        .background(tokens.sidebar)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: StatusBarIcon.image())
                .renderingMode(.template)
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundStyle(tokens.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Clippy")
                    .font(SettingsTypography.brand(settings))
                    .foregroundStyle(tokens.textPrimary)
                Text("Settings")
                    .font(SettingsTypography.brandSubtitle(settings))
                    .foregroundStyle(tokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Clear the window's traffic-light controls (transparent titlebar).
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button { selection = section } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((isSelected ? tokens.accent : tokens.textSecondary).gradient)
                        .frame(width: 22, height: 22)
                    Image(systemName: section.icon)
                        .font(SettingsTypography.sidebarIcon(settings))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                Text(section.title)
                    .font(SettingsTypography.sidebarRow(settings, selected: isSelected))
                    .foregroundStyle(tokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(tokens.accent.opacity(0.18)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(SettingsTypography.footer(settings))
                .symbolRenderingMode(.hierarchical)
            Text("Clippy \(Bundle.main.shortVersion)")
                .font(SettingsTypography.footer(settings))
        }
        .foregroundStyle(tokens.textSecondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selection.title)
                    .font(SettingsTypography.detailTitle(settings))
                    .foregroundStyle(tokens.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralSettingsTab()
        case .appearance: AppearanceSettingsTab()
        case .capture: CaptureSettingsTab()
        case .ai: AISettingsTab()
        case .scripts: ScriptsView()
        case .integrations: IntegrationsSettingsTab()
        }
    }
}

/// The settings sections, in sidebar order, each with a System-Settings-style
/// colored icon tile.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, capture, ai, scripts, integrations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .capture: return "Capture"
        case .ai: return "AI"
        case .scripts: return "Scripts"
        case .integrations: return "Integrations"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .capture: return "doc.on.clipboard.fill"
        case .ai: return "sparkles"
        case .scripts: return "terminal.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        }
    }
}

extension Bundle {
    /// CFBundleShortVersionString, or a dev fallback when running unbundled.
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

/// Settings-window typography. Audit finding: the settings chrome used raw
/// .font(.system(size:)), so the user's panel font family never applied here.
/// These helpers mirror PanelTypography's approach (respect fontFamily and
/// fontSizeBase) so the settings window follows the same font choice as the
/// panel. Sizes are fixed per role (the settings layout is denser than the
/// panel and should not scale with fontSizeBase), but the family tracks the
/// user's choice. System-default falls back to .system so semantic designs
/// (rounded wordmark) still apply.
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
    static func brand(_ s: AppSettings) -> Font {
        make(size: 16, weight: .bold, design: .rounded, s)
    }

    /// The "Settings" subtitle under the wordmark.
    static func brandSubtitle(_ s: AppSettings) -> Font {
        make(size: 11, weight: .regular, s)
    }

    /// The glyph inside a sidebar section tile.
    static func sidebarIcon(_ s: AppSettings) -> Font {
        make(size: 11, weight: .semibold, s)
    }

    /// A sidebar row label. Weight tracks selection.
    static func sidebarRow(_ s: AppSettings, selected: Bool) -> Font {
        make(size: 13, weight: selected ? .semibold : .regular, s)
    }

    /// The footer version line.
    static func footer(_ s: AppSettings) -> Font {
        make(size: 10, weight: .regular, s)
    }

    /// The large section title at the top of the detail pane.
    static func detailTitle(_ s: AppSettings) -> Font {
        make(size: 22, weight: .bold, design: .rounded, s)
    }

    /// The checkmark on a selected accent swatch.
    static func swatchCheck(_ s: AppSettings) -> Font {
        make(size: 9, weight: .bold, s)
    }
}

/// A typed test/install outcome so the UI can render success and failure with
/// distinct icons and colors. Audit finding: test-connection results were
/// rendered as plain secondary Text with no success/failure visual distinction.
/// This mirrors the key-save pattern (checkmark/xmark + colored) already used
/// for the API-key save indicator.
private struct StatusOutcome: Equatable {
    let succeeded: Bool
    let message: String
}

private struct StatusOutcomeLabel: View {
    let outcome: StatusOutcome
    var successColor: Color
    var failureColor: Color = Color.red

    var body: some View {
        Label {
            Text(outcome.message)
        } icon: {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .font(.caption)
        .foregroundStyle(outcome.succeeded ? successColor : failureColor)
        .textSelection(.enabled)
    }
}

/// A TextField that validates on commit (not per keystroke) and shows an inline
/// error. Audit finding: AI endpoint URL, model, and 1Password vault name had
/// no inline validation. Reuses the CustomColorRow commit pattern: a local
/// draft so a half-typed invalid value never writes through to settings.
private struct ValidatedTextField: View {
    let title: String
    var prompt: Text? = nil
    @Binding var value: String
    /// Returns an error message when the committed input is invalid, nil when
    /// it is acceptable. Empty string handling is the caller's responsibility.
    let validate: (String) -> String?

    @State private var draft: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: $draft, prompt: prompt)
                .onSubmit { commit() }
                .foregroundStyle(error != nil ? Color.red : Color.primary)
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { draft = value }
        // Keep the draft in sync when the stored value changes elsewhere
        // (reset-to-defaults, another window) so the field does not show stale
        // text after an external change.
        .onChange(of: value) { _, newValue in
            if newValue != draft { draft = newValue; error = nil }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let msg = validate(trimmed) {
            error = msg
            return
        }
        error = nil
        value = trimmed
        draft = trimmed
    }
}

/// Pushes an NSAppearance onto the hosting window. Used so changing the theme
/// repaints the settings window (a grouped Form) in matching light/dark.
private struct WindowAppearanceApplier: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = appearance
        // The hosting window is often nil during the first layout pass, so defer
        // to the next runloop turn. Apply only when the value actually changed to
        // avoid redundant repaints, and no-op while the window is still nil.
        Task { @MainActor in
            guard let window = view.window, window.appearance != target else { return }
            window.appearance = target
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var showResetConfirmation = false

    private var isRunningFromBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Open panel", value: "\u{2318}\u{21E7}V")
                Text("Press this combination anywhere to open the Clippy panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pasting") {
                Toggle("Paste as plain text by default", isOn: $settings.pastePlainTextByDefault)
                Toggle("Move pasted item to top of history", isOn: $settings.movePastedItemToTop)
                Text("Shift+Return in the panel always pastes in the non-default mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Clicking a clip copies it without pasting", isOn: $settings.clickCopyOnly)
                Text("Off by default: clicking pastes into the active app. Turn on to only copy to the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Keystroke typing speed", selection: $settings.keystrokeSpeed) {
                    ForEach(KeystrokeSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                Text(settings.keystrokeSpeed.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Confirm before typing more than \(settings.keystrokeWarnThreshold) characters",
                    value: $settings.keystrokeWarnThreshold,
                    in: 200...20000,
                    step: 200
                )
                Text("The \"Send as keystrokes\" action prompts before typing a clip this long.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper(
                    "Keep at most \(settings.maxHistoryItems) items",
                    value: $settings.maxHistoryItems,
                    in: 50...10000,
                    step: 50
                )
                Text("Clips in categories never count against the cap and survive Clear Unpinned History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow a clip in multiple categories", isOn: $settings.allowMultipleCategories)
                    .help("Off by default: filing a clip into a category removes it from any other category, so each clip lives in exactly one. On: a clip can belong to several categories at once.")
            }

            Section("Behavior") {
                Toggle("Hide panel when clicking away", isOn: $settings.hideOnClickAway)
                    .help("Close the panel automatically when you click into another app. Off by default: the panel stays open until you press Escape, use the hotkey, or pick a clip.")
                Text("Off by default: the panel stays open until you dismiss it explicitly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hide panel after pasting", isOn: $settings.hideAfterPaste)
                    .help("Close the panel after a paste, primary-click, or Send as keystrokes action. Turn off to keep the panel open for rapid multi-paste workflows.")
                Text("Turn off to paste multiple clips without reopening the panel each time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Escape closes the panel", isOn: $settings.hideOnEscape)
                    .help("Pressing Escape dismisses the panel. Turn off if you want Escape to cancel text in the search field without closing the panel.")

                Picker("Panel window level", selection: $settings.panelFloatLevel) {
                    ForEach(PanelFloatLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .help("Controls how the panel stacks relative to other windows. \"Always on top\" is the default and keeps it above every app window.")
                Text("\"Always on top\" floats above every window. \"Normal\" lets other windows cover the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Pin panel open", isOn: $settings.panelPinned)
                    .help("Suppress all auto-hide triggers (click-away, after-paste, Escape) so the panel stays open regardless of other behavior settings. Use the hotkey or the X button to close it manually.")
                Text("When pinned, the panel ignores all auto-hide rules. Close it manually with the hotkey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logging") {
                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(ClippyLog.LogLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .help("Minimum severity written to Console.app and the rotating log file at ~/Library/Application Support/Clippy/Logs. Verbose is loudest; Error is quietest.")
                .onChange(of: settings.logLevel) { _, level in
                    // Push the live change to the logger immediately so the new
                    // threshold takes effect without restarting the app.
                    ClippyLog.threshold = level
                }
                Text("Lower levels capture more detail for diagnosis. Higher levels keep the log quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Clippy at login", isOn: $launchAtLogin)
                    .disabled(!isRunningFromBundle)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if !isRunningFromBundle {
                    Text("Available when running the bundled Clippy.app (scripts/make-app.sh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Reset") {
                // Audit finding: no global "Reset all settings to defaults". The
                // destructive action is gated by a confirmation dialog so a
                // misclick does not wipe a configured setup. Keychain secrets and
                // the clip database are untouched.
                Button("Reset all settings to defaults...", role: .destructive) {
                    showResetConfirmation = true
                }
                Text("Restores every setting above to its default value. API keys in the keychain and your clip history are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Audit finding: launchAtLogin was snapshotted once at view init, so an
        // external change to the login-item status (System Settings, another
        // build) left the toggle stale. Re-sync from the service on appear.
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset all settings", role: .destructive) {
                settings.resetAllToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores every Clippy setting to its default. Your API keys and clip history are not affected.")
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Only font families that are installed on this machine.
    private var availableFamilies: [PanelFontFamily] {
        PanelFontFamily.allCases.filter { $0.isAvailable }
    }

    /// The fully resolved token table (preset base + accent + any overrides).
    /// Each customize-colors row uses the matching token as its starting value so
    /// an unset override shows the active theme's color, not a placeholder.
    private var resolved: ThemeTokens { settings.theme }

    var body: some View {
        Form {
            // MARK: Theme
            Section("Theme") {
                Picker("Theme", selection: $settings.themePreset) {
                    ForEach(ThemePreset.selectable) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                ThemeSwatchStrip(tokens: settings.theme, themeName: settings.themePreset.label)

                Picker("System appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.themePreset != .system)
                if settings.themePreset != .system {
                    Text("Light/dark is set by the chosen theme. Pick \"Match system\" to follow macOS instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Accent color")
                    HStack(spacing: 8) {
                        ForEach(AccentTheme.allCases) { theme in
                            accentSwatch(theme)
                        }
                    }
                    Text("Applies on top of any theme. Used for selection, links, and the pin marker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Transparency
            Section("Transparency") {
                LabeledContent("Opacity: \(Int(settings.panelOpacity * 100))") {
                    Slider(value: $settings.panelOpacity, in: 0.3...1.0, step: 0.05)
                }
                Text("100% is fully solid. Lower values let the desktop show through a blur behind the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Customize colors (overrides on top of the active preset)
            Section {
                customColorRow("Text (primary)", $settings.customTextPrimaryHex, resolved.textPrimary)
                customColorRow("Text (secondary)", $settings.customTextSecondaryHex, resolved.textSecondary)
                customColorRow("Accent", $settings.customAccentHex, resolved.accent)
                customColorRow("Success", $settings.customSuccessHex, resolved.success)
                customColorRow("Danger", $settings.customDangerHex, resolved.danger)
                customColorRow("Card inner surface", $settings.customCardSurfaceHex, resolved.cardSurface)
                customColorRow("Card border", $settings.customCardBorderHex, resolved.cardBorder)
                customColorRow("Scroll area background", $settings.customScrollBgHex, resolved.scrollBackground)
                customColorRow("Panel background", $settings.customPanelHex, resolved.panel)
                customColorRow("Header bar", $settings.customHeaderHex, resolved.headerBar)
                customColorRow("Footer bar", $settings.customFooterHex, resolved.footerBar)
                customColorRow("Category sidebar", $settings.customSidebarHex, resolved.sidebar)
                HStack {
                    Button("Reset all overrides") { settings.clearColorOverrides() }
                    Spacer()
                }
                .padding(.top, 2)
            } header: {
                Text("Customize colors")
            } footer: {
                Text("Overrides apply on top of the selected theme. Clear a row to fall back to that theme's color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Cards
            Section("Cards") {
                Picker("Card style", selection: $settings.cardStyle) {
                    ForEach(CardStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("Columns", selection: $settings.clipColumns) {
                    Text("Single column").tag(1)
                    ForEach(2...4, id: \.self) { n in
                        Text("\(n) columns").tag(n)
                    }
                }
                Text("Single column shows wide rows. Two to four columns show a card grid filled left to right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Card color", selection: $settings.cardColorMode) {
                    ForEach(CardColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("\"By source app\" tints each card with the app icon's dominant color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Tint strength slider only makes a visible difference for Filled and Bordered.
                if settings.cardStyle != .plain {
                    LabeledContent("Color tint: \(settings.cardTintStrength)%") {
                        Slider(
                            value: Binding(
                                get: { Double(settings.cardTintStrength) },
                                set: { settings.cardTintStrength = Int($0) }
                            ),
                            in: 0...20,
                            step: 1
                        )
                    }
                }

                Toggle("High-contrast card text", isOn: $settings.highContrastCardText)
                Text("Uses primary label color on both title and preview text instead of subdued gray.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show app icons on cards", isOn: $settings.showAppIcons)
                Toggle("Group clips under date headers", isOn: $settings.showSectionHeaders)
            }

            // MARK: Typography
            Section("Typography") {
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(availableFamilies) { family in
                        Text(family.label).tag(family)
                    }
                }

                LabeledContent("Size: \(settings.fontSizeBase) pt") {
                    Slider(
                        value: Binding(
                            get: { Double(settings.fontSizeBase) },
                            set: { settings.fontSizeBase = Int($0) }
                        ),
                        in: 11...16,
                        step: 1
                    )
                }
                Text("Applies to clip titles, preview text, and sidebar labels. The settings window uses the system font.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Panel size and position
            Section("Panel size and position") {
                Picker("Open at", selection: $settings.positionMode) {
                    ForEach(PanelPositionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                LabeledContent("Width: \(Int(settings.panelWidth)) pt") {
                    Slider(value: $settings.panelWidth, in: 300...800, step: 20)
                }
                LabeledContent("Height: \(Int(settings.panelHeight)) pt") {
                    Slider(value: $settings.panelHeight, in: 280...900, step: 20)
                }
                Toggle("Remember last panel size", isOn: $settings.rememberPanelSize)
            }
        }
        .formStyle(.grouped)
    }

    private func accentSwatch(_ theme: AccentTheme) -> some View {
        let isSelected = settings.accentTheme == theme
        return Button {
            settings.accentTheme = theme
        } label: {
            Circle()
                .fill(theme.color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 2)
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(SettingsTypography.swatchCheck(settings))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(theme.label)
    }

    /// One editable surface color: a hex field plus the macOS color wheel, both
    /// bound to the same stored override hex. `resolved` is the color currently
    /// shown by the active theme, used as the starting value when no override is set.
    private func customColorRow(_ title: String, _ hex: Binding<String>, _ resolved: Color) -> some View {
        CustomColorRow(title: title, hex: hex, resolved: resolved)
    }
}

/// One per-token override editor: a hex field plus the macOS color wheel, both
/// writing the same stored override hex, with a reset that clears it. The text
/// field validates on commit (not per keystroke) so an invalid entry never
/// repaints the app the fallback magenta: a bad value is rejected and flagged
/// inline instead of being written back to settings. When the override is empty
/// the row shows `resolved`, the color the active theme currently renders.
private struct CustomColorRow: View {
    let title: String
    let hex: Binding<String>
    /// Active theme's color for this token; shown when no override is set.
    let resolved: Color

    /// Local editable copy so keystrokes do not write straight through to the
    /// stored hex (which would repaint live with partial/invalid input).
    @State private var draft: String = ""
    @State private var isInvalid = false

    /// True when this token has an override pinned (non-empty hex).
    private var hasOverride: Bool {
        !hex.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var color: Binding<Color> {
        Binding(
            // No override: show the resolved theme color. The wheel then writes
            // the first edit as a new override.
            get: { hasOverride ? Color(themeHex: hex.wrappedValue, fallback: resolved) : resolved },
            set: { newColor in
                let value = newColor.themeHexString
                hex.wrappedValue = value
                draft = value
                isInvalid = false
            }
        )
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    TextField(resolved.themeHexString, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 92)
                        .foregroundStyle(isInvalid ? Color.red : (hasOverride ? Color.primary : Color.secondary))
                        .onSubmit { commit() }
                    ColorPicker("", selection: color, supportsOpacity: false)
                        .labelsHidden()
                    // Reset clears the override so this token falls back to the
                    // active theme. Hidden (kept for layout) when nothing to reset.
                    Button {
                        hex.wrappedValue = ""
                        draft = ""
                        isInvalid = false
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the theme's color")
                    .disabled(!hasOverride)
                    .opacity(hasOverride ? 1 : 0.35)
                }
                if isInvalid {
                    Text("Enter a hex color like #1F2328.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { draft = hex.wrappedValue }
        // Keep the field in sync when the stored value changes elsewhere
        // (color wheel, Reset all overrides, per-row reset).
        .onChange(of: hex.wrappedValue) { _, newValue in
            if newValue != draft { draft = newValue; isInvalid = false }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field clears the override (fall back to the theme color).
        if trimmed.isEmpty {
            hex.wrappedValue = ""
            isInvalid = false
            return
        }
        // NSColor(themeHex:) returns nil for anything that is not a valid
        // #RGB/#RRGGBB/#RRGGBBAA value, so it doubles as the validity check.
        guard NSColor(themeHex: trimmed) != nil else {
            isInvalid = true
            return
        }
        isInvalid = false
        let normalized = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
        hex.wrappedValue = normalized
        draft = normalized
    }
}

/// Five-swatch preview of the active theme (panel, card, two text tones, accent)
/// so the user sees a palette change before opening the panel.
private struct ThemeSwatchStrip: View {
    let tokens: ThemeTokens
    let themeName: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color)
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        // Decorative swatches carry no per-rectangle meaning, so collapse them
        // into one element that announces the active theme to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme preview: \(themeName)")
    }

    private var swatches: [Color] {
        [tokens.panel, tokens.cardSurface, tokens.textSecondary, tokens.textPrimary, tokens.accent]
    }
}

// MARK: - Capture

private struct CaptureSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var ignoredAppsText = AppSettings.shared.ignoredBundleIDs.joined(separator: "\n")
    @State private var ignoredAppsError: String?
    @FocusState private var ignoredAppsFocused: Bool
    @State private var soundVolumeSlider: Double = Double(AppSettings.shared.captureSoundVolume)

    private var tokens: ThemeTokens { settings.theme }

    /// Distinct catalog groups, in first-seen order, for the sectioned picker.
    private var soundGroups: [String] {
        var seen = Set<String>()
        return SoundCatalog.options.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                LabeledContent("Polling interval: \(Int(settings.pollingIntervalMs)) ms") {
                    Slider(value: $settings.pollingIntervalMs, in: 100...1000, step: 50)
                }
                Text("Lower is more responsive; higher uses less idle CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Images") {
                Toggle("Capture copied images", isOn: $settings.captureImages)
                Stepper(
                    "Largest image to keep: \(settings.maxImageSizeMB) MB",
                    value: $settings.maxImageSizeMB,
                    in: 1...100
                )
                Text("Bigger copies are ignored to keep the history database lean.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Files") {
                Toggle("Capture copied files", isOn: $settings.captureFiles)
                Stepper(
                    "Store file contents up to: \(settings.maxFileSizeMB) MB",
                    value: $settings.maxFileSizeMB,
                    in: 1...500,
                    step: 5
                )
                Text("When you copy a file, Clippy keeps its actual contents if the file is at or below this size, so it can be pasted later even if the original moves. Larger files are kept as a reference to their location only. Note: stored file contents are retained locally; avoid copying files with sensitive client data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                Toggle("Play sound on capture", isOn: $settings.captureSoundEnabled)

                LabeledContent("Sound") {
                    HStack(spacing: 8) {
                        Picker("Sound", selection: $settings.captureSoundID) {
                            ForEach(soundGroups, id: \.self) { group in
                                Section(group) {
                                    ForEach(SoundCatalog.options.filter { $0.group == group }) { option in
                                        Text(option.label).tag(option.id)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        // Audition immediately on selection change, the way the
                        // macOS Sound preference pane does.
                        .onChange(of: settings.captureSoundID) { _, id in
                            SoundPlayer.play(id: id, volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume))
                        }

                        // Preview button: plays the selected sound at the
                        // current volume so the user can audition without saving.
                        Button {
                            SoundPlayer.play(
                                id: settings.captureSoundID,
                                volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume)
                            )
                        } label: {
                            Image(systemName: "play.circle")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("Preview selected sound")
                    }
                }
                .disabled(!settings.captureSoundEnabled)

                LabeledContent("Volume: \(Int(soundVolumeSlider))%") {
                    Slider(
                        value: $soundVolumeSlider,
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { editing in
                            // Commit on release; preview so the user can hear
                            // the level change immediately.
                            if !editing {
                                settings.captureSoundVolume = Int(soundVolumeSlider)
                                SoundPlayer.play(
                                    id: settings.captureSoundID,
                                    volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume)
                                )
                            }
                        }
                    )
                }
                .disabled(!settings.captureSoundEnabled)
            }

            Section("Ignored apps") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bundle IDs, one per line (e.g. com.apple.keychainaccess)")
                        .font(.caption)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $ignoredAppsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 90)
                            .clipShape(.rect(cornerRadius: 6))
                            .focused($ignoredAppsFocused)
                            // Commit on focus loss instead of per keystroke so a
                            // half-typed bundle ID is not persisted, and so invalid
                            // entries can be flagged rather than silently kept.
                            .onChange(of: ignoredAppsFocused) { _, focused in
                                if !focused { commitIgnoredApps() }
                            }
                        if ignoredAppsText.isEmpty {
                            Text("com.apple.keychainaccess\ncom.1password.1password")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(tokens.cardBorder, lineWidth: 1)
                    )
                    if let ignoredAppsError {
                        Text(ignoredAppsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Always skipped") {
                Label(
                    "Concealed clipboard items (password managers such as 1Password and Bitwarden)",
                    systemImage: "key.slash"
                )
                Label("Transient and auto-generated clipboard writes", systemImage: "clock.badge.xmark")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        // Audit finding: ignoredAppsText/soundVolumeSlider were snapshotted once
        // at init, so an external change to the settings (reset, another window)
        // left the local draft stale. Re-sync on change, guarding the text
        // editor so an in-progress edit is not clobbered.
        .onChange(of: settings.ignoredBundleIDs) { _, newValue in
            let joined = newValue.joined(separator: "\n")
            if !ignoredAppsFocused && joined != ignoredAppsText {
                ignoredAppsText = joined
            }
        }
        .onChange(of: settings.captureSoundVolume) { _, newValue in
            if Double(newValue) != soundVolumeSlider { soundVolumeSlider = Double(newValue) }
        }
    }

    /// Parse the editor on focus loss: persist only well-formed bundle IDs and
    /// report any rejected lines inline rather than storing garbage silently.
    private func commitIgnoredApps() {
        let lines = ignoredAppsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let valid = lines.filter(Self.isPlausibleBundleID)
        let invalid = lines.filter { !Self.isPlausibleBundleID($0) }
        settings.ignoredBundleIDs = valid
        ignoredAppsError = invalid.isEmpty
            ? nil
            : "Ignored invalid bundle ID(s): \(invalid.joined(separator: ", "))"
    }

    /// A reverse-DNS bundle ID is dot-separated alphanumeric/hyphen labels, at
    /// least two of them (e.g. com.apple.finder). This rejects obvious typos
    /// such as spaces, leading dots, or single-word entries without coupling to
    /// any external validator.
    private static func isPlausibleBundleID(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.allSatisfy { label in
            !label.isEmpty && CharacterSet(charactersIn: String(label)).isSubset(of: allowed)
        }
    }
}

// MARK: - Integrations

private struct AISettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    private var tokens: ThemeTokens { settings.theme }
    // Audit finding: switching provider cleared apiKey, discarding in-progress
    // entry. Keep a per-provider draft so typing a key for OpenAI then tabbing
    // to Anthropic and back restores the OpenAI draft.
    @State private var apiKeyDrafts: [AIProviderKind: String] = [:]
    @State private var keyStatus = ""
    @State private var testResult: StatusOutcome?
    @State private var testing = false

    /// The draft API key for the currently selected provider.
    private var currentDraft: String { apiKeyDrafts[settings.aiProvider] ?? "" }

    /// Binding into the per-provider draft map for the SecureField.
    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { currentDraft },
            set: { apiKeyDrafts[settings.aiProvider] = $0 }
        )
    }

    var body: some View {
        Form {
            Section("AI features") {
                Toggle("Enable AI and agentic features", isOn: $settings.aiEnabled)
                Text("Clippy can suggest titles, rewrite text, suggest a category, and draft new clips using the provider below. Proposed changes are shown for your approval before anything is written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                // Audit finding: no inline validation for Model. Reject model ids
                // with internal spaces (a common typo) on commit; empty is valid
                // because it falls back to the provider default.
                ValidatedTextField(
                    title: "Model",
                    prompt: Text(settings.aiProvider.defaultModel),
                    value: $settings.aiModel,
                    validate: { input in
                        guard !input.isEmpty else { return nil }
                        if input.contains(" ") { return "Model ids cannot contain spaces." }
                        return nil
                    }
                )
                Text(settings.aiProvider.modelHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Audit finding: no inline validation for Endpoint URL. Validate
                // it parses as an http/https URL on commit; empty falls back to the
                // provider default and is therefore allowed.
                ValidatedTextField(
                    title: "Endpoint URL",
                    prompt: Text(settings.aiProvider.defaultBaseURL),
                    value: $settings.aiBaseURL,
                    validate: { input in
                        guard !input.isEmpty else { return nil }
                        guard let url = URL(string: input),
                              let scheme = url.scheme?.lowercased(),
                              scheme == "http" || scheme == "https"
                        else { return "Enter a valid http:// or https:// URL." }
                        return nil
                    }
                )
                if settings.aiProvider == .azureFoundry {
                    TextField("API version", text: $settings.aiAzureAPIVersion)
                }
                if settings.aiProvider.needsAPIKey {
                    SecureField("API key", text: apiKeyBinding, prompt: Text("Paste, then Save"))
                    HStack(spacing: 8) {
                        Button("Save key") { saveKey() }
                            .disabled(currentDraft.isEmpty)
                        Button("Clear") { clearKey() }
                        if !keyStatus.isEmpty {
                            let keySaved = keyStatus.hasPrefix("Key")
                            Label {
                                Text(keyStatus)
                            } icon: {
                                Image(systemName: keySaved ? "checkmark.circle.fill" : "xmark.circle")
                                    .symbolRenderingMode(.hierarchical)
                            }
                                .font(.caption)
                                .foregroundStyle(keySaved ? tokens.success : tokens.textSecondary)
                        }
                    }
                } else {
                    Text("Ollama runs locally and needs no API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 8) {
                    Button(testing ? "Testing..." : "Test AI connection") { test() }
                        // Audit finding: "Test AI connection" was disabled until
                        // aiEnabled. Testing is read-only (a sample completion
                        // request), so allow it regardless of the master switch.
                        .disabled(testing)
                    if let testResult {
                        StatusOutcomeLabel(outcome: testResult,
                                            successColor: tokens.success)
                    }
                }
            }

            Section("Automation") {
                Toggle("Auto-suggest a title for new clips", isOn: $settings.aiAutoSuggestTitles)
                    .disabled(!settings.aiEnabled)
                Text("The only action applied automatically. Everything else asks first, and titles can be edited or cleared anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                AIActionsManagerView()
                    .frame(height: 220)
            }
            .disabled(!settings.aiEnabled)

            Section("Agent and tools") {
                Toggle("Allow AI to search the web", isOn: $settings.aiAgentAllowWebSearch)
                    .disabled(!settings.aiEnabled)
                Text("When on, the AI Assistant can search the web for current information. Your search query is sent to DuckDuckGo. On by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow AI to run my scripts", isOn: $settings.aiAgentAllowScripts)
                    .disabled(!settings.aiEnabled)
                Text("When on, the AI Assistant can list and run your saved scripts. You will be shown a confirmation prompt each time before a script runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow AI to execute generated code", isOn: $settings.aiAgentAllowCodeExecution)
                    .disabled(!settings.aiEnabled)
                Text("When on, the AI Assistant can write and execute code. The code runs as you with full environment access and a 30-second timeout. You will be shown the code and asked to confirm before each run. Both options are off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshKeyStatus()
        }
        // Audit finding: refreshKeyStatus cleared apiKey on every provider change,
        // discarding in-progress entry. It now only updates the keyStatus indicator
        // and leaves the per-provider drafts intact. Two-arg .onChange per the
        // standardization finding.
        .onChange(of: settings.aiProvider) { _, _ in
            refreshKeyStatus()
        }
    }

    private func refreshKeyStatus() {
        // Audit finding: do not clear the draft here. Only refresh the indicator
        // so switching providers preserves a half-typed key per provider.
        guard settings.aiProvider.needsAPIKey else { keyStatus = ""; return }
        keyStatus = KeychainStore.shared.has(account: settings.aiProvider.keychainAccount)
            ? "Key stored in Keychain."
            : "No key saved."
    }

    private func saveKey() {
        let ok = KeychainStore.shared.write(
            currentDraft,
            account: settings.aiProvider.keychainAccount,
            label: "Clippy - \(settings.aiProvider.displayName) API key",
            description: "Clippy AI API key for \(settings.aiProvider.displayName)."
        )
        keyStatus = ok ? "Key saved to Keychain." : "Could not save to Keychain."
        apiKeyDrafts[settings.aiProvider] = ""
    }

    private func clearKey() {
        KeychainStore.shared.delete(account: settings.aiProvider.keychainAccount)
        refreshKeyStatus()
    }

    private func test() {
        testing = true
        testResult = nil
        switch AIService.fromSettings() {
        case .failure(let error):
            testResult = StatusOutcome(succeeded: false, message: error.localizedDescription)
            testing = false
        case .success(let service):
            Task {
                do {
                    let proposal = try await service.suggestTitle(
                        forText: "The quick brown fox jumps over the lazy dog.")
                    await MainActor.run {
                        testResult = StatusOutcome(
                            succeeded: true,
                            message: "Connected. Sample title: \(proposal.proposed)")
                        testing = false
                    }
                } catch {
                    await MainActor.run {
                        testResult = StatusOutcome(succeeded: false, message: error.localizedDescription)
                        testing = false
                    }
                }
            }
        }
    }
}

private struct IntegrationsSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var cloud = ICloudSyncService.shared
    @ObservedObject private var mcpController = McpServerController.shared
    private var tokens: ThemeTokens { settings.theme }
    @State private var exportResult: String?
    @State private var archiveResult: String?
    // Audit finding: MCP was filed under "AI". The MCP sections live here now.
    // Audit finding: isPortFree was called inline on every body render. Cache it
    // and recompute only when the port or the server status changes.
    @State private var portFree: Bool = true
    // Audit finding: the install probe showed empty circles while still
    // loading, indistinguishable from "not installed". Track loading state.
    @State private var installedClientsLoading = false
    // Audit finding: refreshInstalledClients shelled out on every tab appearance.
    // Cache the probe result with a TTL and only re-probe on explicit action.
    @State private var lastClientsRefresh: Date = .distantPast
    @State private var mcpInstalledClients: Set<McpClient> = []
    // Audit finding: install blocked the main thread. Per-client installing state
    // drives both the button label and a ProgressView while the async install
    // runs.
    @State private var installingClients: Set<McpClient> = []
    @State private var mcpTestResult: StatusOutcome?
    @State private var mcpTesting = false
    @State private var mcpInstallOutcome: StatusOutcome?

    /// TTL for the installed-clients cache. Re-probing "claude mcp list" on every
    /// tab appearance is wasteful; 30s is short enough to reflect an external
    /// install but long enough to avoid repeated shell-outs while browsing.
    private static let clientsRefreshTTL: TimeInterval = 30

    var body: some View {
        Form {
            Section("Categories and pins") {
                LabeledContent("Pinned archive") {
                    HStack {
                        Button("Export clippy.toml...") { exportTOML() }
                        Button("Import clippy.toml...") { importTOML() }
                    }
                }
                if let archiveResult {
                    Text(archiveResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("clippy.toml is a human-readable file of every category (name, color, icon, order) and the clips pinned into it. Edit it in any text editor and re-import to make bulk changes. Importing is non-destructive: it adds and updates, never clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Export history") {
                    Button("Export as JSON...") { exportJSON() }
                }
                if let exportResult {
                    Text(exportResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Database") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ClipDatabase.shared.databaseURL])
                    }
                }
                Text("Everything is stored locally in a SQLite file you can inspect or back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("1Password") {
                Toggle("Show 1Password vault in the sidebar", isOn: $settings.onePasswordEnabled)
                // Audit finding: no inline validation for vault name. Reject an
                // empty vault name when the 1Password sidebar is on, since the op
                // CLI cannot resolve a vault without a name.
                ValidatedTextField(
                    title: "Vault name",
                    prompt: Text("Clippy"),
                    value: $settings.onePasswordVault,
                    validate: { input in
                        if settings.onePasswordEnabled && input.isEmpty {
                            return "Enter a vault name, or turn off the 1Password sidebar."
                        }
                        return nil
                    }
                )
                Toggle("Auto-clear clipboard after copying a secret",
                       isOn: $settings.onePasswordAutoClearClipboard)
                if settings.onePasswordAutoClearClipboard {
                    Stepper(
                        "Clear after \(settings.onePasswordAutoClearDelaySecs) seconds",
                        value: $settings.onePasswordAutoClearDelaySecs,
                        in: 10...600,
                        step: 10
                    )
                    Text("The pasteboard is only cleared if it still holds the copied secret (no effect if you have already pasted or copied something else).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: OnePasswordService.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(OnePasswordService.isInstalled ? tokens.success : tokens.textSecondary)
                    Text(OnePasswordService.isInstalled
                         ? "1Password CLI (op) found."
                         : "1Password CLI (op) not found. Enable it in 1Password 8 > Developer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Secrets in this vault appear as a sidebar category. Expanding an item shows all its fields; each field can be copied individually. Concealed values are revealed in-place with a toggle. TOTP codes are fetched fresh on each copy. Nothing is recorded in history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iCloud sync") {
                Toggle("Sync clips and categories through iCloud Drive", isOn: $settings.iCloudSyncEnabled)
                    .onChange(of: settings.iCloudSyncEnabled) { _, enabled in
                        if enabled { ICloudSyncService.shared.startIfEnabled() }
                    }
                HStack {
                    Button(cloud.syncing ? "Syncing..." : "Sync now") {
                        Task { await ICloudSyncService.shared.sync() }
                    }
                    .disabled(!settings.iCloudSyncEnabled || cloud.syncing || !cloud.isAvailable)
                    // The service reports a write failure through `status` as a
                    // "Sync failed: ..." string; flag that inline in red the same
                    // way the launch-at-login error is shown, instead of letting
                    // it read as ordinary secondary status text.
                    Text(cloud.isAvailable ? cloud.status : "iCloud Drive is off on this Mac.")
                        .font(.caption)
                        .foregroundStyle(syncStatusFailed ? Color.red : Color.secondary)
                }
                Text("Writes your categories and pinned clips to an iCloud Drive file (iCloud Drive > Clippy) that your other Macs read on sync. Non-destructive: it merges, never clears. No CloudKit, no special entitlement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Audit finding: MCP was filed under "AI". Moved here so the MCP
            // server lives alongside the other integrations.
            Section("MCP server") {
                Toggle("Enable Clippy MCP server", isOn: $settings.mcpEnabled)
                Text("Runs a local server so AI tools (Claude, Copilot) can read and search your clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", value: $settings.mcpPort, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Label {
                            Text(portFree ? "Port \(settings.mcpPort) is available"
                                          : "Port \(settings.mcpPort) is in use")
                        } icon: {
                            Image(systemName: portFree ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.hierarchical)
                        }
                            .font(.caption)
                            .foregroundStyle(portFree ? tokens.success : tokens.danger)
                    }
                }
                .disabled(!settings.mcpEnabled)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(mcpStatusColor)
                            .frame(width: 8, height: 8)
                        Text(mcpController.status.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Install for...") {
                ForEach(McpClient.allCases) { client in
                    HStack {
                        if installedClientsLoading && !mcpInstalledClients.contains(client) {
                            // Audit finding: while the probe is running, show a
                            // spinner instead of an empty circle so "loading" is
                            // distinguishable from "not installed".
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                            Text(client.displayName)
                                .foregroundStyle(tokens.textSecondary)
                        } else if mcpInstalledClients.contains(client) {
                            Label {
                                Text(client.displayName)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                            }
                                .foregroundStyle(tokens.success)
                        } else {
                            Label {
                                Text(client.displayName)
                            } icon: {
                                Image(systemName: "circle")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(tokens.textSecondary)
                            }
                        }
                        Spacer()
                        // Audit finding: no Uninstall. Swap the button to
                        // "Uninstall" when installed. The action runs async with a
                        // per-client installing state so the main thread is not
                        // blocked on a subprocess.
                        Button(installingClients.contains(client) ? "Working..." : (mcpInstalledClients.contains(client) ? "Uninstall" : "Install")) {
                            toggleInstall(client)
                        }
                        .disabled(!settings.mcpEnabled || installingClients.contains(client))
                    }
                }
                if let mcpInstallOutcome {
                    StatusOutcomeLabel(outcome: mcpInstallOutcome,
                                        successColor: tokens.success)
                }
                if !settings.mcpEnabled {
                    Text("Enable the MCP server above before installing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Button(mcpTesting ? "Testing..." : "Test MCP server") {
                        mcpTest()
                    }
                    .disabled(mcpTesting || !mcpController.status.isRunning)
                    if let mcpTestResult {
                        StatusOutcomeLabel(outcome: mcpTestResult,
                                            successColor: tokens.success)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            updatePortFree()
            refreshInstalledClients()
        }
        .onChange(of: settings.mcpPort) { _, _ in updatePortFree() }
        .onChange(of: mcpController.status.isRunning) { _, _ in
            // The server status affects isPortFree (a running server holds the
            // port, which the helper treats as free-for-us). Recompute on change.
            // McpServerStatus itself is not Equatable, so observe the Bool.
            updatePortFree()
        }
    }

    // MARK: - MCP helpers

    private var mcpStatusColor: Color {
        switch mcpController.status {
        case .running:   return .green
        case .starting:  return .yellow
        case .stopped:   return .secondary
        case .portInUse: return .orange
        case .failed:    return .red
        }
    }

    private func updatePortFree() {
        portFree = mcpController.isPortFree(settings.mcpPort)
    }

    private func refreshInstalledClients(force: Bool = false) {
        // Audit finding: shelling out on every tab appearance. Skip when the
        // cache is still fresh unless the caller forces a refresh (after an
        // install/uninstall action).
        let now = Date()
        if !force && now.timeIntervalSince(lastClientsRefresh) < Self.clientsRefreshTTL {
            return
        }
        lastClientsRefresh = now
        installedClientsLoading = true
        // isInstalled(.claudeCode) can spawn a login shell ("zsh -l -c which
        // claude") and run "claude mcp list", each blocking for hundreds of ms.
        // Probe off the main thread so opening this tab never freezes the window.
        Task.detached(priority: .utility) {
            var found = Set<McpClient>()
            for client in McpClient.allCases where await McpInstallService.isInstalled(client) {
                found.insert(client)
            }
            await MainActor.run { [found] in
                mcpInstalledClients = found
                installedClientsLoading = false
            }
        }
    }

    /// Install or uninstall the client depending on its current state. Runs
    /// the subprocess async on a detached task so the button does not pin the
    /// main thread (audit finding: install blocked on a DispatchSemaphore).
    private func toggleInstall(_ client: McpClient) {
        let isInstalled = mcpInstalledClients.contains(client)
        installingClients.insert(client)
        let port = settings.mcpPort
        Task.detached(priority: .utility) {
            let result: Result<String, Error> = isInstalled
                ? await McpInstallService.remove(client)
                : await McpInstallService.install(client, port: port)
            await MainActor.run {
                installingClients.remove(client)
                switch result {
                case .success(let msg):
                    mcpInstallOutcome = StatusOutcome(succeeded: true, message: msg)
                    // Force a refresh so the row reflects the new state immediately.
                    refreshInstalledClients(force: true)
                case .failure(let err):
                    mcpInstallOutcome = StatusOutcome(succeeded: false, message: err.localizedDescription)
                }
            }
        }
    }

    private func mcpTest() {
        mcpTesting = true
        mcpTestResult = nil
        McpServerController.shared.testConnection { result in
            switch result {
            case .success(let count):
                mcpTestResult = StatusOutcome(
                    succeeded: true,
                    message: count > 0
                        ? "Connected. \(count) tool\(count == 1 ? "" : "s") available."
                        : "Connected.")
            case .failure(let err):
                mcpTestResult = StatusOutcome(succeeded: false, message: err.localizedDescription)
            }
            mcpTesting = false
        }
    }

    /// True when the iCloud service has reported a sync write failure. The
    /// service surfaces failures by setting `status` to a "Sync failed:" string,
    /// so match that prefix rather than adding a property to that service.
    private var syncStatusFailed: Bool {
        cloud.isAvailable && cloud.status.hasPrefix("Sync failed")
    }

    /// Shared NSSavePanel scaffold. Returns the result string to display, or nil
    /// when the user cancelled (so the caller leaves the prior message intact).
    private func runSavePanel(name: String, types: [UTType],
                              _ body: (URL) throws -> String) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try body(url) }
        catch { return "Export failed: \(error.localizedDescription)" }
    }

    /// Shared NSOpenPanel scaffold. Same cancel semantics as runSavePanel.
    private func runOpenPanel(types: [UTType],
                              _ body: (URL) throws -> String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try body(url) }
        catch { return "Import failed: \(error.localizedDescription)" }
    }

    private func exportTOML() {
        let result = runSavePanel(name: "clippy.toml",
                                  types: [UTType(filenameExtension: "toml") ?? .plainText]) { url in
            let toml = try ClippyArchive.exportTOML(from: ClipDatabase.shared)
            try toml.write(to: url, atomically: true, encoding: .utf8)
            return "Exported categories and pinned clips to \(url.lastPathComponent)."
        }
        if let result { archiveResult = result }
    }

    private func importTOML() {
        let result = runOpenPanel(types: [UTType(filenameExtension: "toml") ?? .plainText, .plainText, .text]) { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let summary = try ClippyArchive.importTOML(text, into: ClipDatabase.shared)
            var message = "Imported \(summary.categories) categories and \(summary.clips) clips."
            if summary.skippedImages > 0 {
                message += " Skipped \(summary.skippedImages) image(s) whose files were missing."
            }
            return message
        }
        if let result { archiveResult = result }
    }

    private func exportJSON() {
        struct ExportClip: Encodable {
            let text: String
            let kind: String
            let mediaFile: String?
            let sourceApp: String?
            let sourceBundleID: String?
            let createdAt: Date
            let categories: [String]
        }
        struct ExportDocument: Encodable {
            let note: String
            let clips: [ExportClip]
        }

        let result = runSavePanel(name: "clippy-export.json", types: [.json]) { url in
            let database = ClipDatabase.shared
            let categories = try database.categories()
            let membership = try database.membershipMap()
            let nameByID = Dictionary(
                uniqueKeysWithValues: categories.compactMap { category in
                    category.id.map { ($0, category.name) }
                }
            )
            let clips = try database.allClips().map { clip in
                ExportClip(
                    text: clip.contentText,
                    kind: clip.contentKind.rawValue,
                    mediaFile: clip.mediaFilename.map { database.media.url(for: $0).path },
                    sourceApp: clip.sourceAppName,
                    sourceBundleID: clip.sourceAppBundleID,
                    createdAt: clip.createdAt,
                    categories: (clip.id.flatMap { membership[$0] } ?? [])
                        .compactMap { nameByID[$0] }
                        .sorted()
                )
            }
            let document = ExportDocument(
                note: "Image clips reference PNG files under the Clippy media folder; copy them separately if you need a portable backup.",
                clips: clips
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url)
            return "Exported \(clips.count) clips to \(url.lastPathComponent)."
        }
        if let result { exportResult = result }
    }
}
