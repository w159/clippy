import AppKit
import SwiftUI

/// Settings for text expansion: toggle, delimiter, case, exclusions and permission status.
struct SnippetsSettingsPane: View {
    @State private var enabled = SnippetSettings.isExpansionEnabled
    @State private var mode = SnippetSettings.triggerMode
    @State private var caseSensitive = SnippetSettings.isCaseSensitive
    @State private var allowEnv = SnippetSettings.allowEnvironmentPlaceholder
    @State private var excluded = SnippetSettings.excludedBundleIDs.joined(separator: "\n")
    @State private var trusted = CaretLocator.isTrusted

    /// Creates the pane.
    init() {}

    var body: some View {
        Form {
            Section {
                SettingsRow(title: "Expand snippets while typing",
                            detail: Text("Watches keystrokes system-wide to spot abbreviations. Typed text stays in memory and is never stored or sent.")) {
                    Toggle("", isOn: $enabled).labelsHidden().onChange(of: enabled) { _, value in apply { SnippetSettings.isExpansionEnabled = value } }
                }
                SettingsRow(title: "Accessibility permission") {
                    HStack {
                        Label(trusted ? "Granted" : "Not granted", systemImage: trusted ? "checkmark.circle" : "exclamationmark.triangle")
                        if !trusted { Button("Open System Settings", action: openAccessibility) }
                        Button("Refresh") { trusted = CaretLocator.isTrusted; apply {} }
                    }
                }
                SettingsRow(title: "Expand when") {
                    Picker("", selection: $mode) {
                        Text("Followed by space, return or tab").tag(SnippetTriggerMode.onDelimiter)
                        Text("Immediately").tag(SnippetTriggerMode.immediate)
                    }.labelsHidden().onChange(of: mode) { _, value in apply { SnippetSettings.triggerMode = value } }
                }
                SettingsRow(title: "Case-sensitive abbreviations") {
                    Toggle("", isOn: $caseSensitive).labelsHidden().onChange(of: caseSensitive) { _, value in
                        apply { SnippetSettings.isCaseSensitive = value }
                    }
                }
                SettingsRow(title: "Allow {env:NAME} placeholders", detail: Text("Off by default; lets a snippet read environment variables.")) {
                    Toggle("", isOn: $allowEnv).labelsHidden().onChange(of: allowEnv) { _, value in
                        apply { SnippetSettings.allowEnvironmentPlaceholder = value }
                    }
                }
            }
            Section("Excluded apps") {
                TextEditor(text: $excluded).font(.system(.body, design: .monospaced)).frame(minHeight: 100)
                    .onChange(of: excluded) { _, value in
                        apply { SnippetSettings.excludedBundleIDs = value.split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    }
                Text("Bundle IDs, one per line. Password managers and terminals are excluded by default. Expansion also pauses in secure text fields and while Clippy is locked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func apply(_ change: () -> Void) {
        change()
        if SnippetSettings.isExpansionEnabled { SnippetExpander.shared.reloadSnippets(); SnippetExpander.shared.start() }
        else { SnippetExpander.shared.stop() }
    }

    private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}
