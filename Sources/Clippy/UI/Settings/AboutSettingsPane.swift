import AppKit
import Sparkle
import SwiftUI

// About pane: version/build, update check, links, licenses, content-free diagnostics.

struct AboutSettingsPane: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var copied = false

    /// Diagnostics text: versions and switches only. Never clip content, titles, keys or paths of user data.
    static func diagnosticsText(settings: AppSettings = .shared, bundle: Bundle = .main,
                                os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        [
            "Clippy \(bundle.shortVersion) (\(bundle.buildNumber))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "AI enabled: \(settings.aiEnabled), provider: \(AIProviderStore.shared.active?.name ?? "Not configured")",
            "MCP enabled: \(settings.mcpEnabled), iCloud sync: \(settings.iCloudSyncEnabled)",
            "Log level: \(settings.logLevel.label)",
            "Managed keys: \(AppSettings.forcedKeys.count)",
        ].joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section("Clippy") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Build", value: Bundle.main.buildNumber)
                if let updater = Self.updater {
                    Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } else {
                    SettingsNote("Updates are available in the packaged Clippy.app.")
                }
            }
            .settingsRow("about")
            Section("Links") {
                Link("Clippy on GitHub", destination: URL(string: "https://github.com/w159/clippy")!)
                    .foregroundStyle(Color.clippyAccent)
                Link("Report an issue", destination: URL(string: "https://github.com/w159/clippy/issues")!)
                    .foregroundStyle(Color.clippyAccent)
            }
            Section("Licenses") {
                SettingsNote("Clippy uses GRDB.swift (MIT), TOMLKit (MIT), swift-markdown-ui (MIT) and Sparkle (MIT). Full license texts ship inside the app bundle.")
            }
            Section("Diagnostics") {
                Text(Self.diagnosticsText()).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.diagnosticsText(), forType: .string)
                        copied = true
                    }
                    if copied { SettingsStatusLine(kind: .success, text: "Copied") }
                }
                SettingsNote("Diagnostics contain versions and setting switches only, never clip content or keys.")
            }
            SettingsPaneActionsSection()
        }
        .formStyle(.grouped)
    }

    /// The app's Sparkle updater, only in a packaged build (one with a feed URL).
    /// The old lookup searched the main menu, but the update item lives in the
    /// status-bar menu, so this button never appeared.
    private static var updater: SPUUpdater? {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return (NSApp.delegate as? AppDelegate)?.updaterController.updater
    }
}

#Preview("About") { AboutSettingsPane().clippyDesignSystem().frame(width: 560, height: 520) }
