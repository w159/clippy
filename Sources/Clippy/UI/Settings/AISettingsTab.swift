import AppKit
import SwiftUI

// The AI settings tab.

struct AISettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.clippyTokens) private var tokens
    // Audit finding: switching provider cleared apiKey, discarding in-progress
    // entry. Keep a per-provider draft so typing a key for OpenAI then tabbing
    // to Anthropic and back restores the OpenAI draft.
    @State private var apiKeyDrafts: [AIProviderKind: String] = [:]
    @State private var keyStatus = ""
    @State private var testResult: StatusOutcome?
    @State private var testing = false

    /// The draft API key for the currently selected provider.
    private var currentDraft: String { apiKeyDrafts[settings.aiProvider] ?? "" }

    /// Binding into the per-provider draft map for the SecureField.
    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { currentDraft },
            set: { apiKeyDrafts[settings.aiProvider] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            aiForm
            Divider()
            // SET-07: the actions list is its own pane region, never nested in the Form's scroller.
            DisclosureGroup("AI actions") {
                AIActionsManagerView()
                    .frame(minHeight: 220, maxHeight: 320)
            }
            .settingsRow("ai.actions")
            .padding(.horizontal, 22).padding(.vertical, 8)
            .disabled(!settings.aiEnabled)
        }
        .task { refreshKeyStatus() }
        .onChange(of: settings.aiProvider) { _, _ in refreshKeyStatus() }
    }

    private var aiForm: some View {
        Form {
            Section("AI features") {
                Toggle("Enable AI and agentic features", isOn: $settings.aiEnabled)
                    .settingsManaged(AppSettings.Keys.aiEnabled)
                    .settingsRow("ai.enabled")
                Text("Suggest titles, rewrite text, pick categories and draft clips. Changes are shown for approval first.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }

            Section("Provider") {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                // Apple Intelligence has no model to pick and no endpoint to
                // reach, so those fields are hidden rather than shown inert.
                if settings.aiProvider.needsEndpointConfiguration {
                    // Audit finding: no inline validation for Model. Reject model ids
                    // with internal spaces (a common typo) on commit; empty is valid
                    // because it falls back to the provider default.
                    ValidatedTextField(
                        title: "Model",
                        prompt: Text(settings.aiProvider.defaultModel),
                        value: $settings.aiModel,
                        validate: { input in
                            guard !input.isEmpty else { return nil }
                            if input.contains(" ") { return "Model ids cannot contain spaces." }
                            return nil
                        }
                    )
                }
                Text(settings.aiProvider.modelHint)
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                if settings.aiProvider.needsEndpointConfiguration {
                    // Audit finding: no inline validation for Endpoint URL. Validate
                    // it parses as an http/https URL on commit; empty falls back to the
                    // provider default and is therefore allowed.
                    ValidatedTextField(
                        title: "Endpoint URL",
                        prompt: Text(settings.aiProvider.defaultBaseURL),
                        value: $settings.aiBaseURL,
                        validate: { input in
                            guard !input.isEmpty else { return nil }
                            guard let url = URL(string: input),
                                  let scheme = url.scheme?.lowercased(),
                                  scheme == "http" || scheme == "https"
                            else { return "Enter a valid http:// or https:// URL." }
                            return nil
                        }
                    )
                }
                if settings.aiProvider == .azureFoundry {
                    TextField("API version", text: $settings.aiAzureAPIVersion)
                }
                if settings.aiProvider.needsAPIKey {
                    SecureField("API key", text: apiKeyBinding, prompt: Text("Paste, then Save"))
                        .settingsRow("ai.key")
                    HStack(spacing: 8) {
                        Button("Save key") { saveKey() }
                            .disabled(currentDraft.isEmpty)
                        Button("Clear") { clearKey() }
                        if !keyStatus.isEmpty {
                            let keySaved = keyStatus.hasPrefix("Key")
                            Label {
                                Text(keyStatus)
                            } icon: {
                                Image(systemName: keySaved ? "checkmark.circle.fill" : "xmark.circle")
                                    .symbolRenderingMode(.hierarchical)
                            }
                                .font(.caption)
                                .foregroundStyle(keySaved ? tokens.success : tokens.textSecondary)
                        }
                    }
                } else if settings.aiProvider == .appleIntelligence {
                    if let why = AppleIntelligence.availability.reason {
                        Label(why, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(tokens.danger)
                    } else {
                        Label("Ready. Runs on this Mac, no key required.",
                              systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(tokens.success)
                    }
                } else {
                    Text("Ollama runs locally and needs no API key.")
                        .font(.caption)
                        .foregroundStyle(tokens.textSecondary)
                }
                Divider()
                HStack(spacing: 8) {
                    Button(testing ? "Testing..." : "Test AI connection") { test() }
                        // Audit finding: "Test AI connection" was disabled until
                        // aiEnabled. Testing is read-only (a sample completion
                        // request), so allow it regardless of the master switch.
                        .disabled(testing)
                    if let testResult {
                        StatusOutcomeLabel(outcome: testResult,
                                            successColor: tokens.success)
                    }
                }
            }

            Section("Automation") {
                Toggle("Auto-suggest a title for new clips", isOn: $settings.aiAutoSuggestTitles)
                    .disabled(!settings.aiEnabled)
                Text("The only action applied automatically. Titles can be edited or cleared anytime.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                // This one fires on every copy, so it is hard-gated on a provider
                // that keeps the text on this Mac. Saying so beats a toggle that
                // is on and quietly does nothing.
                if settings.aiAutoSuggestTitles && !settings.aiProvider.runsLocally {
                    Label(
                        "Paused: \(settings.aiProvider.displayName) is a hosted provider, and this runs on every copy. Switch to Apple Intelligence or Ollama to enable it.",
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(tokens.danger)
                }
            }

            Section("Agent and tools") {
                SettingsStatusLine(kind: .warning, text: "Code and script execution runs as you, with your permissions. Review every confirmation prompt.")
                Toggle("Allow AI to search the web", isOn: $settings.aiAgentAllowWebSearch)
                    .disabled(!settings.aiEnabled)
                    .settingsManaged(AppSettings.Keys.aiAgentAllowWebSearch)
                Text("Queries are sent to DuckDuckGo. Off by default.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                Toggle("Allow AI to run my scripts", isOn: $settings.aiAgentAllowScripts)
                    .disabled(!settings.aiEnabled)
                    .settingsManaged(AppSettings.Keys.aiAgentAllowScripts)
                Text("You confirm each run. Off by default.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                Toggle("Allow AI to execute generated code", isOn: $settings.aiAgentAllowCodeExecution)
                    .disabled(!settings.aiEnabled)
                    .settingsManaged(AppSettings.Keys.aiAgentAllowCodeExecution)
                Text("Runs as you with a 30-second timeout. You see the code and confirm each run. Off by default.")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    private func refreshKeyStatus() {
        // Audit finding: do not clear the draft here. Only refresh the indicator
        // so switching providers preserves a half-typed key per provider.
        guard settings.aiProvider.needsAPIKey else { keyStatus = ""; return }
        keyStatus = KeychainStore.shared.has(account: settings.aiProvider.keychainAccount)
            ? "Key stored in Keychain."
            : "No key saved."
    }

    private func saveKey() {
        let saved = KeychainStore.shared.write(
            currentDraft,
            account: settings.aiProvider.keychainAccount,
            label: "Clippy - \(settings.aiProvider.displayName) API key",
            description: "Clippy AI API key for \(settings.aiProvider.displayName)."
        )
        keyStatus = saved ? "Key saved to Keychain." : "Could not save to Keychain. Your entry was kept; try again."
        // SET-06: clear the draft only after a successful Keychain write.
        if saved { apiKeyDrafts[settings.aiProvider] = "" }
    }

    private func clearKey() {
        KeychainStore.shared.delete(account: settings.aiProvider.keychainAccount)
        refreshKeyStatus()
    }

    private func test() {
        testing = true
        testResult = nil
        switch AIService.fromSettings() {
        case .failure(let error):
            testResult = StatusOutcome(succeeded: false, message: error.localizedDescription)
            testing = false
        case .success(let service):
            Task {
                do {
                    let proposal = try await service.suggestTitle(
                        forText: "The quick brown fox jumps over the lazy dog.")
                    await MainActor.run {
                        testResult = StatusOutcome(
                            succeeded: true,
                            message: "Connected. Sample title: \(proposal.proposed)")
                        testing = false
                    }
                } catch {
                    await MainActor.run {
                        testResult = StatusOutcome(succeeded: false, message: error.localizedDescription)
                        testing = false
                    }
                }
            }
        }
    }
}

#Preview("AI") { AISettingsTab().clippyDesignSystem().frame(width: 640, height: 720) }
