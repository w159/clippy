import SwiftUI

/// App lock (Touch ID / password) settings plus the managed-preferences status list.
struct SecurityAppLockSection: View {
    @Environment(\.clippyTokens) private var tokens
    @Binding var notice: PaneNotice?
    @State private var enabled = AppLockPreferences().isEnabled
    @State private var idleMinutes = AppLockPreferences().idleMinutes
    @State private var testing = false

    private let preferences = AppLockPreferences()

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    private var lockForced: Bool { AppSettings.isForced(AppLockPreferences.enabledKey) }
    private var idleForced: Bool { AppSettings.isForced(AppLockPreferences.idleMinutesKey) }
    private var forcedKeys: [String] { ManagedSettingKeys.all.filter { AppSettings.isForced($0) } }

    var body: some View {
        Group {
            PaneSection("App lock", footer: "When on, the panel asks for Touch ID or your password every time it opens and after the idle time below.") {
                SettingsRow(title: "Require authentication", detail: lockForced ? Text("Set by your organization.") : nil, enabled: !lockForced) {
                    Toggle("Require authentication", isOn: $enabled).labelsHidden()
                        .onChange(of: enabled) { _, value in
                            preferences.isEnabled = value
                            AppLock.shared.preferencesChanged()
                        }
                }
                Divider()
                SettingsRow(title: "Lock after idle", detail: Text("\(idleMinutes) minute\(idleMinutes == 1 ? "" : "s")"), enabled: enabled && !idleForced) {
                    Stepper("Lock after idle", value: $idleMinutes, in: AppLockPreferences.idleRange).labelsHidden()
                        .onChange(of: idleMinutes) { _, value in
                            preferences.idleMinutes = value
                            AppLock.shared.preferencesChanged()
                        }
                }
                Divider()
                SettingsRow(title: "Test authentication", detail: Text("Checks that Touch ID or your password works. Does not lock the app.")) {
                    Button(testing ? "Waiting\u{2026}" : "Test") { runTest() }.disabled(testing)
                }
            }
            managedSection
        }
    }

    private var managedSection: some View {
        PaneSection("Managed by your organization", footer: "Locked settings come from an MDM configuration profile and cannot be changed here.") {
            if forcedKeys.isEmpty {
                SettingsRow(title: "No settings are locked", detail: Text("Every setting can be changed on this Mac.")) { EmptyView() }
            } else {
                ForEach(forcedKeys, id: \.self) { key in
                    SettingsRow(title: LocalizedStringKey(key)) {
                        Image(systemName: "lock.fill").foregroundStyle(tokens.textSecondary).accessibilityLabel("Locked")
                    }
                    Divider()
                }
            }
        }
    }

    private func runTest() {
        testing = true
        LocalAuthenticator().authenticate(reason: "Test Clippy authentication") { success in
            DispatchQueue.main.async {
                testing = false
                notice = success ? .success("Authentication succeeded.") : .failure("Authentication failed or was cancelled.")
            }
        }
    }
}
