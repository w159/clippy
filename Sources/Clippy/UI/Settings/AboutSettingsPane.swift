import AppKit
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
            "AI enabled: \(settings.aiEnabled), provider: \(settings.aiProvider.displayName)",
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
                if let item = Self.updateMenuItem {
                    Button("Check for Updates\u{2026}") { NSApp.sendAction(item.action!, to: item.target, from: item) }
                } else {
                    SettingsNote("Updates are available in the packaged Clippy.app.")
                }
            }
            .settingsRow("about")
            Section("Links") {
                Link("Clippy on GitHub", destination: URL(string: "https://github.com/w159/clippy")!)
                Link("Report an issue", destination: URL(string: "https://github.com/w159/clippy/issues")!)
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
        }
        .formStyle(.grouped)
    }

    /// The app menu's Sparkle item, when the updater is wired.
    private static var updateMenuItem: NSMenuItem? {
        NSApp.mainMenu?.items.compactMap { $0.submenu?.items }.joined()
            .first { $0.title.hasPrefix("Check for Updates") && $0.action != nil && $0.isEnabled }
    }
}

#Preview("About") { AboutSettingsPane().clippyDesignSystem().frame(width: 560, height: 520) }
