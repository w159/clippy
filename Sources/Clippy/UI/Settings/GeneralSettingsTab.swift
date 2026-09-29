import AppKit
import SwiftUI

// The General settings pane (hotkey, pasting, history, behavior, logging, startup, external editor).

struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.clippyTokens) private var tokens
    @State private var launchStatus = LaunchAtLogin.status
    @State private var launchError: String?
    @State private var showResetConfirmation = false
    @State private var editors: [ExternalEditorChoice] = []
    @State private var editorID: String = ExternalEditorPreference.bundleID() ?? ""

    var body: some View {
        Form {
            ShortcutsSettingsSection()
            pastingSection
            historySection
            behaviorSection
            startupSection
            SettingsAdvanced(anchors: ["general.logLevel", "general.externalEditor", "general.reset"]) {
                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(ClippyLog.LogLevel.allCases) { Text($0.label).tag($0) }
                }
                .settingsRow("general.logLevel")
                .help("Minimum severity written to Console.app and the rotating log file.")
                .onChange(of: settings.logLevel) { _, level in ClippyLog.threshold = level }
                SettingsNote("Info is the default. Lower levels capture more detail for diagnosis.")
                Picker("External editor", selection: $editorID) {
                    Text("Automatic").tag("")
                    ForEach(editors) { Text($0.name).tag($0.bundleID) }
                }
                .settingsRow("general.externalEditor")
                .onChange(of: editorID) { _, id in ExternalEditorPreference.setBundleID(id.isEmpty ? nil : id) }
                SettingsNote("The app used by \"Edit in External Editor\". Automatic prefers Sublime Text, then the system default.")
                Button("Reset all settings to defaults\u{2026}", role: .destructive) { showResetConfirmation = true }
                    .settingsRow("general.reset")
                SettingsNote("Restores every setting to its default. API keys in the keychain and your clip history are not affected.")
            }
        }
        .formStyle(.grouped)
        .task {
            editors = ExternalEditorPreference.installedEditors()
            launchStatus = LaunchAtLogin.status
        }
        .confirmationDialog("Reset all settings to defaults?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset all settings", role: .destructive) { settings.resetAllToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores every Clippy setting to its default. Your API keys and clip history are not affected.")
        }
    }

    // MARK: - Sections

    private var pastingSection: some View {
        Section("Pasting") {
            Toggle("Paste as plain text by default", isOn: $settings.pastePlainTextByDefault).settingsRow("general.plainText")
            // The Shift+Return note belongs to the plain-text toggle above.
            SettingsNote("Shift+Return in the panel always pastes in the non-default mode.")
            Toggle("Move pasted item to top of history", isOn: $settings.movePastedItemToTop).settingsRow("general.moveToTop")
            Toggle("Clicking a clip copies it without pasting", isOn: $settings.clickCopyOnly).settingsRow("general.clickCopyOnly")
            SettingsNote("Off by default: clicking pastes into the active app.")
            Picker("Keystroke typing speed", selection: $settings.keystrokeSpeed) {
                ForEach(KeystrokeSpeed.allCases) { Text($0.label).tag($0) }
            }
            .settingsRow("general.keystrokeSpeed")
            SettingsNote(settings.keystrokeSpeed.detail)
            LabeledContent("Confirm before typing more than") {
                Stepper(value: $settings.keystrokeWarnThreshold, in: 200...20000, step: 200) {
                    Text("\(settings.keystrokeWarnThreshold) characters")
                        .monospacedDigit().frame(minWidth: 110, alignment: .trailing)
                }
            }
            .settingsRow("general.keystrokeWarn")
            SettingsNote("The \"Send as keystrokes\" action prompts before typing a clip this long.")
        }
    }

    private var historySection: some View {
        Section("History") {
            LabeledContent("Keep at most") {
                Stepper(value: $settings.maxHistoryItems, in: 50...10000, step: 50) {
                    Text("\(settings.maxHistoryItems) items").monospacedDigit().frame(minWidth: 110, alignment: .trailing)
                }
            }
            .settingsRow("general.maxHistory")
            SettingsNote("Clips in categories never count against the cap and survive Clear Unpinned History.")
            Toggle("Allow a clip in multiple categories", isOn: $settings.allowMultipleCategories)
                .settingsRow("general.multiCategory")
                .help("Off: filing a clip into a category removes it from any other category.")
        }
    }

    private var behaviorSection: some View {
        Section("Behavior") {
            Toggle("Hide panel when clicking away", isOn: $settings.hideOnClickAway).settingsRow("general.hideClickAway")
            Toggle("Hide panel after pasting", isOn: $settings.hideAfterPaste).settingsRow("general.hideAfterPaste")
            SettingsNote("Turn off to paste several clips without reopening the panel.")
            Toggle("Escape closes the panel", isOn: $settings.hideOnEscape).settingsRow("general.escape")
            Picker("Panel window level", selection: $settings.panelFloatLevel) {
                ForEach(PanelFloatLevel.allCases) { Text($0.label).tag($0) }
            }
            .settingsRow("general.windowLevel")
            Toggle("Pin panel open", isOn: $settings.panelPinned).settingsRow("general.pin")
            SettingsNote("When pinned, the panel ignores all auto-hide rules. Close it with the hotkey.")
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch Clippy at login", isOn: launchBinding)
                .disabled(launchStatus == .notFound)
                .settingsRow("general.launchAtLogin")
            switch launchStatus {
            case .requiresApproval:
                SettingsStatusLine(kind: .warning, text: "Needs approval in System Settings > Login Items.")
                Button("Open Login Items\u{2026}") { LaunchAtLogin.openSystemSettings() }
            case .notFound:
                SettingsNote("Available when running the bundled Clippy.app (scripts/make-app.sh).")
            case .enabled, .disabled:
                EmptyView()
            }
            if let launchError { SettingsStatusLine(kind: .failure, text: launchError) }
        }
    }

    /// Reads the live system status; writes go through `LaunchAtLogin.set`.
    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchStatus == .enabled || launchStatus == .requiresApproval },
            set: { enabled in
                do {
                    try LaunchAtLogin.set(enabled)
                    launchError = nil
                } catch {
                    launchError = "Could not update login item: \(error.localizedDescription)"
                }
                launchStatus = LaunchAtLogin.status
            }
        )
    }
}

#Preview("General") { GeneralSettingsTab().clippyDesignSystem().frame(width: 640, height: 640) }
