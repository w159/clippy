import AppKit
import SwiftUI

// MCP server section: accurate port/status, token rotation, bounded install probes with preview (SET-03).

extension IntegrationsSettingsTab {
    /// Upper bound for one install/uninstall/probe round trip, above the service's own CLI timeout.
    static let installDeadline: TimeInterval = McpInstallService.cliTimeout + 5

    @ViewBuilder
    var mcpSection: some View {
        Section("MCP server") {
            Toggle("Enable Clippy MCP server", isOn: $settings.mcpEnabled).settingsRow("integrations.mcp")
            SettingsNote("Runs a local server so AI tools (Claude, Cursor, Zed and others) can read and search your clips. " +
                "It listens on 127.0.0.1 only and requires a bearer token.")
            LabeledContent("Port") {
                HStack(spacing: 8) {
                    TextField("", value: $portDraft, format: .number.grouping(.never))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .onSubmit { commitPort() }
                        .accessibilityLabel("MCP port")
                    SettingsStatusLine(kind: portKind, text: mcpController.portStatus.summary)
                }
            }
            .settingsRow("integrations.mcpPort")
            .disabled(!settings.mcpEnabled)
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(mcpStatusColor).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(mcpController.status.description).font(.caption).foregroundStyle(tokens.textSecondary).textSelection(.enabled)
                }
            }
            SettingsSecretField(typeLabel: "Access token") {
                await Task.detached { try? McpTokenProvider.shared.token() }.value
            }
            .settingsRow("integrations.mcpToken")
            Button("Rotate token\u{2026}") { showRotateConfirmation = true }
            SettingsNote(tokenNote ?? "Stored in the Keychain and written into installed client configs. Rotating restarts the server " +
                "and re-syncs installed clients; the old token stops working immediately.")
            HStack(spacing: 8) {
                Button(mcpTesting ? "Testing..." : "Test MCP server") { mcpTest() }
                    .disabled(mcpTesting || !mcpController.status.isRunning)
                if let mcpTestResult { StatusOutcomeLabel(outcome: mcpTestResult, successColor: tokens.success) }
            }
        }
        Section("Install for...") {
            ForEach(McpClient.allCases) { client in installRow(client) }
            if let mcpInstallOutcome { StatusOutcomeLabel(outcome: mcpInstallOutcome, successColor: tokens.success) }
            if !settings.mcpEnabled { SettingsNote("Enable the MCP server above before installing.") }
        }
        .settingsRow("integrations.mcpInstall")
    }

    private func installRow(_ client: McpClient) -> some View {
        let installed = mcpInstalledClients.contains(client)
        let working = installingClients.contains(client)
        return HStack {
            if installedClientsLoading && !installed {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
                Text(client.displayName).foregroundStyle(tokens.textSecondary)
            } else {
                Label(client.displayName, systemImage: installed ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(installed ? tokens.success : tokens.textPrimary)
            }
            Spacer()
            Button("Preview") { previewClient = client }
                .disabled(!settings.mcpEnabled)
                .accessibilityLabel("Preview \(client.displayName) config change")
            Button(working ? "Working..." : (installed ? "Uninstall" : "Install")) { toggleInstall(client) }
                .disabled(!settings.mcpEnabled || working)
        }
    }

    var portKind: SettingsStatusLine.Kind {
        switch mcpController.portStatus {
        case .available, .inUseByClippy: return .success
        case .invalid: return .failure
        case .inUseByOther: return .warning
        }
    }

    var mcpStatusColor: Color {
        switch mcpController.status {
        case .running: return tokens.success
        case .starting: return tokens.warning
        case .stopped: return tokens.textSecondary
        case .portInUse: return tokens.warning
        case .failed: return tokens.danger
        }
    }

    /// Commits the typed port when it is bindable; otherwise restores the stored one.
    func commitPort() {
        if (1024...65535).contains(portDraft) { settings.mcpPort = portDraft } else { portDraft = settings.mcpPort }
        Task { @MainActor in mcpController.refreshPortStatus() }
    }

    func refreshInstalledClients(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastClientsRefresh) < Self.clientsRefreshTTL { return }
        lastClientsRefresh = now
        installedClientsLoading = true
        Task { @MainActor in
            let found = await Self.withDeadline(Self.installDeadline, fallback: Set<McpClient>()) {
                var found = Set<McpClient>()
                for client in McpClient.allCases where await McpInstallService.isInstalled(client) { found.insert(client) }
                return found
            }
            mcpInstalledClients = found
            installedClientsLoading = false
        }
    }

    func toggleInstall(_ client: McpClient) {
        let isInstalled = mcpInstalledClients.contains(client)
        installingClients.insert(client)
        let port = settings.mcpPort
        Task { @MainActor in
            let timedOut: Result<String, Error> = .failure(McpInstallError.cliFailed("Timed out"))
            let result = await Self.withDeadline(Self.installDeadline, fallback: timedOut) {
                isInstalled ? await McpInstallService.remove(client) : await McpInstallService.install(client, port: port)
            }
            installingClients.remove(client)
            switch result {
            case .success(let msg):
                mcpInstallOutcome = StatusOutcome(succeeded: true, message: msg)
                refreshInstalledClients(force: true)
            case .failure(let err):
                mcpInstallOutcome = StatusOutcome(succeeded: false, message: err.localizedDescription)
            }
        }
    }

    func rotateToken() {
        McpServerController.shared.rotateToken()
        tokenNote = "Token rotated. The server is restarting and installed clients are being re-synced."
    }

    func mcpTest() {
        mcpTesting = true
        mcpTestResult = nil
        McpServerController.shared.testConnection { result in
            switch result {
            case .success(let count):
                mcpTestResult = StatusOutcome(succeeded: true, message: count > 0
                    ? "Connected. \(count) tool\(count == 1 ? "" : "s") available." : "Connected.")
            case .failure(let err):
                mcpTestResult = StatusOutcome(succeeded: false, message: err.localizedDescription)
            }
            mcpTesting = false
        }
    }

    /// Runs `work` and returns `fallback` if it does not finish within `seconds`.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, fallback: T,
                                          _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return fallback
            }
            let first = await group.next() ?? fallback
            group.cancelAll()
            return first
        }
    }
}

/// Sheet showing exactly what installing would write for a client (token masked).
struct McpPreviewSheet: View {
    let client: McpClient
    let port: Int
    let onClose: () -> Void
    @State private var preview: Result<McpConfigPreview, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(client.displayName) config").font(.headline)
            switch preview {
            case .none: ProgressView().controlSize(.small)
            case .failure(let error): SettingsStatusLine(kind: .failure, text: error.localizedDescription)
            case .success(let value):
                Text(value.fileURL.path).font(.caption).textSelection(.enabled)
                SettingsNote(value.fileExists ? "Existing file; other servers are preserved." : "The file would be created.")
                ScrollView { Text(value.diff.isEmpty ? "No changes." : value.diff).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: 180)
            }
            HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            let target = client
            let value = await Task.detached { Result { try McpInstallService.preview(target, port: port) } }.value
            preview = value
        }
    }
}
