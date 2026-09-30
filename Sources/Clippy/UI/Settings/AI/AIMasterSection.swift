import SwiftUI

struct AIMasterSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: AIProviderStore

    var body: some View {
        PaneSection("AI features") {
            Toggle("Enable AI and agentic features", isOn: $settings.aiEnabled)
                .settingsManaged(AppSettings.Keys.aiEnabled).settingsRow("ai.enabled")
            if SettingsForcedState(key: AppSettings.Keys.aiEnabled).isForced {
                SettingsNote("Managed by your organization")
            }
            SettingsNote("Suggest titles, rewrite text, pick categories and draft clips. Changes are shown for approval first.")
            SettingsNote(AIProviderSettingsLogic.privacyText(AIProviderSettingsLogic.privacy(active: store.presentationInstance())))
            if AIProviderSettingsLogic.ForcedGate().providerLocked {
                SettingsNote("Active provider: \(store.presentationInstance()?.name ?? "Managed provider"). Managed by your organization")
            }
        }
    }
}
