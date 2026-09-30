import AppKit
import SwiftUI

// The AI settings tab.

struct AISettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = AIProviderStore.shared
    @StateObject private var model = AIProviderManagerModel()
    @State private var showActions = false

    var body: some View {
        Form {
            AIMasterSection(settings: settings, store: store)
            AIProviderListSection(model: model, store: store)
            if let managed = store.presentationInstance(), !store.instances.contains(where: { $0.id == managed.id }),
               let descriptor = ProviderCatalog.descriptor(id: managed.descriptorID) {
                PaneSection("Managed provider") {
                    LabeledContent("Provider", value: managed.name)
                    if descriptor.fields.contains(.baseURL) { LabeledContent("Base URL", value: managed.baseURL) }
                    if descriptor.fields.contains(.model) { LabeledContent("Model", value: managed.model) }
                    if descriptor.fields.contains(.deployment) { LabeledContent("Deployment", value: managed.deployment) }
                    if descriptor.fields.contains(.apiVersion) { LabeledContent("API version", value: managed.apiVersion) }
                    SettingsNote("Managed by your organization")
                    SettingsNote(AIProviderSettingsLogic.effectiveURLText(descriptor: descriptor, instance: managed))
                }
            }
            if let instance = store.instances.first(where: { $0.id == model.selectedID }),
               let descriptor = ProviderCatalog.descriptor(id: instance.descriptorID) {
                AIProviderEditor(model: model, instance: instance, descriptor: descriptor).id(instance.id)
            }
            PaneSection("Automation") {
                Toggle("Auto-suggest a title for new clips", isOn: $settings.aiAutoSuggestTitles)
                    .disabled(!settings.aiEnabled).settingsManaged(AppSettings.Keys.aiAutoSuggestTitles)
                    .settingsRow("ai.autoTitle")
                SettingsNote("The only action applied automatically. Titles can be edited or cleared anytime.")
            }
            PaneSection("AI actions") {
                Button("Manage AI actions…") { showActions = true }
                    .settingsRow("ai.actions").disabled(!settings.aiEnabled)
                SettingsNote("Reusable prompts that appear on a clip's menu. Add, edit, reorder or import them.")
            }
            PaneSection("Agent and tools") {
                SettingsStatusLine(kind: .warning, text: "Code and script execution runs as you, with your permissions. Review every confirmation prompt.")
                Toggle("Allow AI to search the web", isOn: $settings.aiAgentAllowWebSearch)
                    .disabled(!settings.aiEnabled).settingsManaged(AppSettings.Keys.aiAgentAllowWebSearch).settingsRow("ai.webSearch")
                SettingsNote("Queries are sent to DuckDuckGo. Off by default.")
                Toggle("Allow AI to run my scripts", isOn: $settings.aiAgentAllowScripts)
                    .disabled(!settings.aiEnabled).settingsManaged(AppSettings.Keys.aiAgentAllowScripts).settingsRow("ai.scripts")
                SettingsNote("You confirm each run. Off by default.")
                Toggle("Allow AI to execute generated code", isOn: $settings.aiAgentAllowCodeExecution)
                    .disabled(!settings.aiEnabled).settingsManaged(AppSettings.Keys.aiAgentAllowCodeExecution).settingsRow("ai.code")
                SettingsNote("Runs as you with a 30-second timeout. You see the code and confirm each run. Off by default.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showActions) {
            VStack(spacing: 0) {
                HStack {
                    Text("AI actions").font(.headline)
                    Spacer()
                    Button("Done") { showActions = false }.keyboardShortcut(.defaultAction)
                }.padding(12)
                Divider()
                AIActionsManagerView()
            }
            .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 380, idealHeight: 520, maxHeight: .infinity)
            .clippyDesignSystem()
        }
    }
}

#Preview("AI") { AISettingsTab().clippyDesignSystem().frame(width: 640, height: 720) }
