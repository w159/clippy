import AppKit
import SwiftUI

// The Appearance settings tab (theme, colors, cards, typography, panel size), with its color-row and swatch helpers.

struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.clippyTokens) private var tokens

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
                        .foregroundStyle(tokens.textSecondary)
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
                        .foregroundStyle(tokens.textSecondary)
                }
            }

            // MARK: Transparency
            Section("Transparency") {
                LabeledContent("Opacity: \(Int(settings.panelOpacity * 100))") {
                    Slider(value: $settings.panelOpacity, in: 0.3...1.0, step: 0.05)
                }
                Text("100% is fully solid. Lower values let the desktop show through a blur behind the panel.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
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
                    .foregroundStyle(tokens.textSecondary)
            }

            // MARK: Layout (density and columns, bound to GridPreferences)
            GridSettingsSection()

            // MARK: Cards
            Section("Cards") {
                Picker("Card style", selection: $settings.cardStyle) {
                    ForEach(CardStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("Card color", selection: $settings.cardColorMode) {
                    ForEach(CardColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("\"By source app\" tints each card with the app icon's dominant color.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)

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
                    .foregroundStyle(tokens.textSecondary)

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
                .settingsRow("appearance.font")

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
                .settingsRow("appearance.fontSize")
                Text("Applies to clip titles, preview text, and sidebar labels. The settings window uses the system font.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }

            // MARK: Panel size and position
            SettingsAdvanced(anchors: ["appearance.position", "appearance.size"]) {
                Picker("Open at", selection: $settings.positionMode) {
                    ForEach(PanelPositionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .settingsRow("appearance.position")
                LabeledContent("Width: \(Int(settings.panelWidth)) pt") {
                    Slider(value: $settings.panelWidth, in: 300...800, step: 20)
                }
                LabeledContent("Height: \(Int(settings.panelHeight)) pt") {
                    Slider(value: $settings.panelHeight, in: 280...900, step: 20)
                }
                Toggle("Remember last panel size", isOn: $settings.rememberPanelSize)
                    .settingsRow("appearance.size")
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
                    Circle().strokeBorder(tokens.strokeStrong.opacity(isSelected ? 1 : 0), lineWidth: 2)
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
struct CustomColorRow: View {
    let title: String
    let hex: Binding<String>
    /// Active theme's color for this token; shown when no override is set.
    let resolved: Color

    @Environment(\.clippyTokens) private var tokens
    /// Local editable copy so keystrokes do not write straight through to the
    /// stored hex (which would repaint live with partial/invalid input).
    @State private var draft: String = ""
    @State private var isInvalid = false
    /// Color shown by the well while dragging; committed to `hex` once the drag settles.
    @State private var pickerColor: Color = .clear
    @State private var commitTask: Task<Void, Never>?

    /// True when this token has an override pinned (non-empty hex).
    private var hasOverride: Bool {
        !hex.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedColor: Color {
        hasOverride ? Color(themeHex: hex.wrappedValue, fallback: resolved) : resolved
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    // One monospaced hex value; the placeholder shows the theme's hex when unset.
                    TextField("", text: $draft, prompt: Text(resolved.themeHexString))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 96)
                        .foregroundStyle(isInvalid ? tokens.danger : (hasOverride ? tokens.textPrimary : tokens.textSecondary))
                        .onSubmit { commit() }
                        .accessibilityLabel("\(title) hex value")
                    ColorPicker("\(title) color", selection: $pickerColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(minWidth: 44)
                    Button {
                        commitTask?.cancel()
                        hex.wrappedValue = ""
                        draft = ""
                        isInvalid = false
                        pickerColor = resolved
                    } label: {
                        Image(systemName: "arrow.uturn.backward").symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the theme's color")
                    .accessibilityLabel("Reset \(title)")
                    .disabled(!hasOverride)
                    .opacity(hasOverride ? 1 : 0.35)
                }
                .fixedSize()
                if isInvalid {
                    Text("Enter a hex color like #1F2328.").font(.caption2).foregroundStyle(tokens.danger)
                }
            }
        } label: {
            Text(title).lineLimit(1)
        }
        .task {
            draft = hex.wrappedValue
            pickerColor = displayedColor
        }
        // Keep the field in sync when the stored value changes elsewhere
        // (Reset all overrides, per-row reset, theme change).
        .onChange(of: hex.wrappedValue) { _, newValue in
            if newValue != draft { draft = newValue; isInvalid = false }
            pickerColor = displayedColor
        }
        // Commit on drag END: the well changes continuously while dragging, so wait
        // until it has been still for a moment before writing the override.
        .onChange(of: pickerColor) { _, newColor in
            let value = newColor.themeHexString
            guard value != hex.wrappedValue, value != (hasOverride ? "" : resolved.themeHexString) else { return }
            commitTask?.cancel()
            commitTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                hex.wrappedValue = value
                draft = value
                isInvalid = false
            }
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
struct ThemeSwatchStrip: View {
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

#Preview("Appearance") { AppearanceSettingsTab().clippyDesignSystem().frame(width: 640, height: 720) }
