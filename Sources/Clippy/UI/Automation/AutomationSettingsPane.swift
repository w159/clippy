import SwiftUI

/// Settings pane for URL scheme, Spotlight and the command line tool.
struct AutomationSettingsPane: View {
    @State private var allowWrites = AutomationSettings().allowURLSchemeWrites
    @State private var spotlight = AutomationSettings().spotlightIndexingEnabled
    @State private var installMessage: String?

    var body: some View {
        Form {
            Section("URL scheme") {
                Toggle("Allow URL scheme writes", isOn: $allowWrites)
                    .onChange(of: allowWrites) { _, value in AutomationSettings().allowURLSchemeWrites = value }
                Text("clippy://add and clippy://paste-latest change data. Off: Clippy asks once per session before running them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotlight") {
                Toggle("Show clips in Spotlight", isOn: $spotlight)
                    .onChange(of: spotlight) { _, value in
                        AutomationSettings().spotlightIndexingEnabled = value
                        if value { ClipSpotlightIndexer.donateRecent() } else { ClipSpotlightIndexer.removeAll() }
                    }
                Text("Titles and short previews of non-sensitive text clips are given to macOS Spotlight. "
                    + "Sensitive clips are never shared. Off by default; turning it off removes them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Command line tool") {
                Button("Install command line tool") { installMessage = install() }
                if let installMessage { Text(installMessage).font(.caption).textSelection(.enabled) }
                Text("Links clippy into /usr/local/bin, or ~/.local/bin when that is not writable. "
                    + "Reads are read-only and never show sensitive clips; writes go through this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func install() -> String {
        switch CLIInstaller.install() {
        case .success(let outcome):
            AutomationSettings().cliInstallPath = outcome.path
            return outcome.message
        case .failure(let error): return error.localizedDescription
        }
    }
}
