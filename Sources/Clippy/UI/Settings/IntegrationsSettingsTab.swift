import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Integrations settings tab (1Password, iCloud, MCP, archive).

struct IntegrationsSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var cloud = ICloudSyncService.shared
    @ObservedObject var mcpController = McpServerController.shared
    @Environment(\.clippyTokens) var tokens
    @State var exportResult: String?
    @State var archiveResult: String?
    // Audit finding: MCP was filed under "AI". The MCP sections live here now.
    // Audit finding: isPortFree was called inline on every body render. Cache it
    // and recompute only when the port or the server status changes.
    @State var portFree: Bool = true
    // Audit finding: the install probe showed empty circles while still
    // loading, indistinguishable from "not installed". Track loading state.
    @State var installedClientsLoading = false
    // Audit finding: refreshInstalledClients shelled out on every tab appearance.
    // Cache the probe result with a TTL and only re-probe on explicit action.
    @State var lastClientsRefresh: Date = .distantPast
    @State var mcpInstalledClients: Set<McpClient> = []
    // Audit finding: install blocked the main thread. Per-client installing state
    // drives both the button label and a ProgressView while the async install
    // runs.
    @State var installingClients: Set<McpClient> = []
    @State var mcpTestResult: StatusOutcome?
    @State var mcpTesting = false
    @State var mcpInstallOutcome: StatusOutcome?
    @State var portDraft = AppSettings.shared.mcpPort
    @State var showRotateConfirmation = false
    @State var tokenNote: String?
    @State var previewClient: McpClient?

    /// TTL for the installed-clients cache. Re-probing "claude mcp list" on every
    /// tab appearance is wasteful; 30s is short enough to reflect an external
    /// install but long enough to avoid repeated shell-outs while browsing.
    static let clientsRefreshTTL: TimeInterval = 30

    var body: some View {
        Form {
            Section("Categories and pins") {
                LabeledContent("Pinned archive") {
                    HStack {
                        Button("Export\u{2026}") { exportTOML() }.help("Export clippy.toml")
                        Button("Import\u{2026}") { importTOML() }.help("Import clippy.toml")
                    }
                }
                .settingsRow("integrations.archive")
                if let archiveResult {
                    Text(archiveResult)
                        .font(.caption)
                        .foregroundStyle(tokens.textSecondary)
                }
                Text("clippy.toml is a human-readable file of every category (name, color, icon, order) and the clips pinned into " +
                    "it. Edit it in any text editor and re-import to make bulk changes. Importing is non-destructive: it adds and " +
                    "updates, never clears.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }

            Section("Data") {
                LabeledContent("Export history") {
                    Button("Export as JSON...") { exportJSON() }
                }
                .settingsRow("integrations.history")
                if let exportResult {
                    Text(exportResult)
                        .font(.caption)
                        .foregroundStyle(tokens.textSecondary)
                }
                LabeledContent("Database") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ClipDatabase.shared.databaseURL])
                    }
                }
                Text("Everything is stored locally in a SQLite file you can inspect or back up.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }

            Section("1Password") {
                Toggle("Show 1Password vault in the sidebar", isOn: $settings.onePasswordEnabled)
                    .settingsRow("integrations.onePassword")
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
                        .foregroundStyle(tokens.textSecondary)
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
                        .foregroundStyle(tokens.textSecondary)
                }
                Text("Secrets in this vault appear as a sidebar category. Expanding an item shows all its fields; each field can be " +
                    "copied individually. Concealed values are revealed in-place with a toggle. TOTP codes are fetched fresh on " +
                    "each copy. Nothing is recorded in history.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }

            iCloudSection

            mcpSection
        }
        .formStyle(.grouped)
        // SET-10: every state write happens in a task after the view update, never in body/onAppear.
        .task {
            portDraft = settings.mcpPort
            mcpController.refreshPortStatus()
            refreshInstalledClients()
        }
        .onChange(of: settings.mcpPort) { _, port in
            portDraft = port
            Task { @MainActor in mcpController.refreshPortStatus() }
        }
        .onChange(of: mcpController.status.isRunning) { _, _ in
            Task { @MainActor in mcpController.refreshPortStatus() }
        }
        .confirmationDialog("Rotate the MCP access token?", isPresented: $showRotateConfirmation, titleVisibility: .visible) {
            Button("Rotate token", role: .destructive) { rotateToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server restarts and installed clients are updated. Anything using the old token stops working.")
        }
        .sheet(item: $previewClient) { client in
            McpPreviewSheet(client: client, port: settings.mcpPort) { previewClient = nil }
        }
    }

    // MARK: - iCloud

    /// SET-04: the toggle is disabled with an explanation when iCloud Drive is off.
    @ViewBuilder
    private var iCloudSection: some View {
        Section("iCloud sync") {
            Toggle("Sync clips and categories through iCloud Drive", isOn: $settings.iCloudSyncEnabled)
                .settingsManaged(AppSettings.Keys.iCloudSyncEnabled)
                .disabled(!cloud.isAvailable)
                .settingsRow("integrations.icloud")
                .onChange(of: settings.iCloudSyncEnabled) { _, enabled in
                    if enabled { ICloudSyncService.shared.startIfEnabled() }
                }
            if !cloud.isAvailable {
                SettingsStatusLine(kind: .warning, text: "iCloud Drive is off on this Mac, so sync is unavailable.")
                Button("Open iCloud settings\u{2026}") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                HStack {
                    Button(cloud.syncing ? "Syncing..." : "Sync now") { Task { await ICloudSyncService.shared.sync() } }
                        .disabled(!settings.iCloudSyncEnabled || cloud.syncing)
                    if syncStatusFailed {
                        SettingsStatusLine(kind: .failure, text: cloud.status)
                    } else {
                        Text(cloud.status).font(.caption).foregroundStyle(tokens.textSecondary)
                    }
                }
            }
            SettingsNote("Writes your categories and pinned clips to an iCloud Drive file (iCloud Drive > Clippy) that your other Macs " +
                "read on sync. Non-destructive: it merges, never clears. No CloudKit, no special entitlement.")
        }
    }
}

#Preview("Integrations") { IntegrationsSettingsTab().clippyDesignSystem().frame(width: 640, height: 700) }
