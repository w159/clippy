import AppKit
import SwiftUI
import UniformTypeIdentifiers

// SET-05: pick apps by bundle id (running apps or /Applications) instead of typing them.

/// Resolved display info for a bundle id.
struct CaptureAppInfo: Identifiable, Equatable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    /// Name from the installed app when known, else the bundle id.
    @MainActor
    static func resolve(_ bundleID: String) -> CaptureAppInfo {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return CaptureAppInfo(bundleID: bundleID, name: bundleID)
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return CaptureAppInfo(bundleID: bundleID, name: name)
    }

    /// Running regular apps, sorted by name, excluding `excluding` and Clippy itself.
    @MainActor
    static func runningApps(excluding: Set<String>) -> [CaptureAppInfo] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> CaptureAppInfo? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                  !excluding.contains(id), seen.insert(id).inserted else { return nil }
            return CaptureAppInfo(bundleID: id, name: app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Menu button offering running apps plus a "Choose from Applications" panel.
struct AppPickerMenu: View {
    let title: String
    let excluded: Set<String>
    let onPick: (String) -> Void
    @State private var running: [CaptureAppInfo] = []

    var body: some View {
        Menu(title) {
            Section("Running apps") {
                ForEach(running) { app in Button(app.name) { onPick(app.bundleID) } }
            }
            Divider()
            Button("Choose from Applications\u{2026}") { chooseFromDisk() }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .task { running = CaptureAppInfo.runningApps(excluding: excluded) }
        .onChange(of: excluded) { _, newValue in running = CaptureAppInfo.runningApps(excluding: newValue) }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = IgnoredAppsParser.bundleID(ofAppAt: url) { onPick(id) }
        }
    }
}

/// Ignored Apps list bound to the stored bundle-id array (key format unchanged).
struct IgnoredAppsSection: View {
    @Binding var bundleIDs: [String]
    @Environment(\.clippyTokens) private var tokens
    @State private var manualEntry = ""
    @State private var manualError: String?

    var body: some View {
        Section("Ignored apps") {
            if bundleIDs.isEmpty { SettingsNote("No apps ignored. Clips copied in ignored apps are never recorded.") }
            ForEach(bundleIDs, id: \.self) { bundleID in
                let info = CaptureAppInfo.resolve(bundleID)
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(info.name)
                        if info.name != bundleID {
                            Text(bundleID).font(.caption).foregroundStyle(tokens.textSecondary)
                        }
                    }
                    Spacer()
                    Button { bundleIDs = IgnoredAppsParser.removing(bundleID, from: bundleIDs) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop ignoring \(info.name)")
                }
            }
            HStack {
                AppPickerMenu(title: "Add app", excluded: Set(bundleIDs)) { bundleIDs = IgnoredAppsParser.adding($0, to: bundleIDs) }
                TextField("Bundle ID", text: $manualEntry, prompt: Text("com.example.app"))
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit(addManual)
            }
            if let manualError { SettingsStatusLine(kind: .failure, text: manualError) }
        }
        .settingsRow("capture.ignoredApps")
    }

    private func addManual() {
        let trimmed = manualEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard IgnoredAppsParser.isPlausibleBundleID(trimmed) else {
            manualError = "\"\(trimmed)\" is not a valid bundle ID."
            return
        }
        manualError = nil
        bundleIDs = IgnoredAppsParser.adding(trimmed, to: bundleIDs)
        manualEntry = ""
    }
}
