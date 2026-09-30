import SwiftUI

// Capture policy rows backed by CapturePreferences and PasteProfiles (UserDefaults-backed, not AppSettings).

/// Capture-on-launch toggle.
struct CaptureLaunchRow: View {
    @State private var captureOnLaunch = CapturePreferences.captureOnLaunch

    var body: some View {
        Toggle("Capture the current clipboard on launch", isOn: $captureOnLaunch)
            .settingsRow("capture.onLaunch")
            .onChange(of: captureOnLaunch) { _, value in CapturePreferences.captureOnLaunch = value }
        SettingsNote("Off by default: whatever you copied before Clippy started is not recorded.")
    }
}

/// Sensitive auto-clear, type blocklist and per-app paste profiles.
struct CapturePolicySections: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var clearSeconds = CapturePreferences.sensitiveAutoClearSeconds
    @State private var deletesHistory = CapturePreferences.autoClearDeletesHistory
    @State private var blocklist = CapturePreferences.typeBlocklist
    @State private var newType = ""
    @State private var overrides = PasteProfiles.overrides

    /// Selectable auto-clear delays in seconds; 0 disables.
    private static let clearOptions = [0, 15, 30, 60, 120, 300]

    var body: some View {
        Section("Sensitive clips") {
            Picker("Auto-clear after", selection: $clearSeconds) {
                ForEach(Self.clearOptions.contains(clearSeconds) ? Self.clearOptions : (Self.clearOptions + [clearSeconds]).sorted(),
                        id: \.self) { Text($0 == 0 ? "Never" : "\($0) seconds").tag($0) }
            }
            .settingsRow("capture.sensitiveClear")
            .onChange(of: clearSeconds) { _, value in CapturePreferences.sensitiveAutoClearSeconds = value }
            Toggle("Also delete from history", isOn: $deletesHistory)
                .disabled(clearSeconds == 0)
                .onChange(of: deletesHistory) { _, value in CapturePreferences.autoClearDeletesHistory = value }
            SettingsNote("Sensitive clips are masked in the panel. Auto-clear removes them from the clipboard and, when on, from history.")
        }
        Section("Ignored pasteboard types") {
            ForEach(blocklist, id: \.self) { type in
                HStack {
                    Text(type).font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).help(type)
                    Spacer(minLength: 8)
                    Button { blocklist.removeAll { $0 == type }; CapturePreferences.typeBlocklist = blocklist } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(type)")
                }
            }
            TextField("Type identifier", text: $newType, prompt: Text("org.nspasteboard.ConcealedType"))
                .font(.system(.caption, design: .monospaced))
                .onSubmit(addType)
            SettingsNote("A copy carrying any of these pasteboard types (or a subtype) is never recorded.")
        }
        .settingsRow("capture.typeBlocklist")
        Section("Paste behavior per app") {
            ForEach(overrides.keys.sorted(), id: \.self) { bundleID in
                LabeledContent(CaptureAppInfo.resolve(bundleID).name) {
                    Picker("Mode", selection: modeBinding(bundleID)) {
                        Text("Follow default").tag(PasteProfiles.Mode.automatic)
                        Text("Always plain text").tag(PasteProfiles.Mode.plainText)
                        Text("Always rich text").tag(PasteProfiles.Mode.rich)
                    }
                    .labelsHidden()
                }
            }
            AppPickerMenu(title: "Add app override", excluded: Set(overrides.keys)) { bundleID in
                PasteProfiles.setMode(.plainText, forBundleID: bundleID)
                overrides = PasteProfiles.overrides
            }
            SettingsNote("Terminals and code editors paste plain text by default. Overrides here win over that built-in list.")
        }
        .settingsRow("capture.pasteProfiles")
    }

    private func modeBinding(_ bundleID: String) -> Binding<PasteProfiles.Mode> {
        Binding(get: { overrides[bundleID] ?? .automatic }, set: { mode in
            PasteProfiles.setMode(mode, forBundleID: bundleID)
            overrides = PasteProfiles.overrides
        })
    }

    private func addType() {
        let trimmed = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blocklist.contains(trimmed) else { return }
        blocklist.append(trimmed)
        CapturePreferences.typeBlocklist = blocklist
        newType = ""
    }
}
