import SwiftUI

/// The shell the pane is shown in, so a pane's closing section can reset, export and import.
/// Nil when a pane is shown outside the Settings window (previews, standalone captures).
private struct SettingsShellKey: EnvironmentKey {
    static let defaultValue: SettingsShellModel? = nil
}

extension EnvironmentValues {
    /// The Settings window's shell model, injected by `SettingsView`.
    var settingsShell: SettingsShellModel? {
        get { self[SettingsShellKey.self] }
        set { self[SettingsShellKey.self] = newValue }
    }
}

/// Final Form section of every pane: Reset this pane, Export and Import as neutral bordered buttons.
struct SettingsPaneActionsSection: View {
    @Environment(\.settingsShell) private var shell

    var body: some View {
        if let shell {
            Section {
                HStack(spacing: 8) {
                    Button("Reset this pane") { shell.showResetConfirmation = true }
                        .disabled(!shell.selection.isResettable)
                    Button("Export\u{2026}") { shell.exportPreferences() }
                    Button("Import\u{2026}") { shell.beginImport() }
                    Spacer(minLength: 8)
                    if let status = shell.status { StatusOutcomeLabel(outcome: status, successColor: .green) }
                }
                .buttonStyle(.bordered)
                .lineLimit(1)
            }
        }
    }
}
