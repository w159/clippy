import SwiftUI

/// The form for the selected instance, generated from `descriptor.fields`.
struct AIProviderDetailSection: View {
    @ObservedObject var model: AIProviderManagerModel
    @Binding var draft: ProviderInstance
    let descriptor: ProviderDescriptor
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.openURL) private var openURL
    private var keyDraft: String { model.keyDrafts[draft.id] ?? "" }
    private var keyBinding: Binding<String> {
        Binding(get: { keyDraft }, set: { model.keyDrafts[draft.id] = $0 })
    }
    @State private var keyStatus: AIProviderManagerModel.KeyStatus = .missing
    @State private var keyError = false
    private let gate = AIProviderSettingsLogic.ForcedGate()

    private var isActive: Bool { model.store.presentationInstance()?.id == draft.id }
    private var effectiveDraft: ProviderInstance {
        guard isActive, let managed = model.store.presentationInstance(draft.id) else { return draft }
        var display = draft
        if locked(.baseURL) { display.baseURL = managed.baseURL }
        if locked(.model) { display.model = managed.model }
        if locked(.deployment) { display.deployment = managed.deployment }
        if locked(.apiVersion) { display.apiVersion = managed.apiVersion }
        return display
    }
    private func fieldBinding(_ field: ProviderField, _ path: WritableKeyPath<ProviderInstance, String>) -> Binding<String> {
        Binding(get: { locked(field) ? effectiveDraft[keyPath: path] : draft[keyPath: path] },
                set: { if !locked(field) { draft[keyPath: path] = $0 } })
    }
    private func show(_ field: ProviderField) -> Bool { AIProviderSettingsLogic.shows(field, for: descriptor) }
    private func locked(_ field: ProviderField) -> Bool { gate.locks(field, isActive: isActive) }

    var body: some View {
        PaneSection(LocalizedStringKey(draft.name.isEmpty ? descriptor.displayName : draft.name)) {
            AIInsetField(title: "Name", text: $draft.name)
            if AIProviderSettingsLogic.visibleFields(descriptor).isEmpty {
                appleStatus
            }
            if show(.baseURL) { baseURLRow }
            if show(.apiKey) { keyRow }
            if show(.model) { modelRow }
            if show(.deployment) { AIInsetField(title: "Deployment", text: fieldBinding(.deployment, \.deployment)).disabled(locked(.deployment)) }
            if show(.apiVersion) {
                AIInsetField(title: "API version", text: fieldBinding(.apiVersion, \.apiVersion),
                             prompt: AIProviderSettingsLogic.defaultAPIVersion(descriptor))
                    .disabled(locked(.apiVersion))
            }
            if show(.organization) { AIInsetField(title: "Organization", text: $draft.organization) }
            if show(.project) { AIInsetField(title: "Project", text: $draft.project) }
            if show(.region) { AIInsetField(title: "Region", text: $draft.region) }
            if locked(.baseURL) || locked(.model) || locked(.apiVersion) {
                SettingsNote("Managed by your organization")
            }
            if AIProviderSettingsLogic.supportsAdvanced(descriptor) {
                SettingsNote(AIProviderSettingsLogic.effectiveURLText(descriptor: descriptor, instance: effectiveDraft)).padding(.vertical, 6)
            }
            if let url = URL(string: descriptor.docsURL), !descriptor.docsURL.isEmpty {
                Button("Open provider docs") { openURL(url) }.buttonStyle(.link).padding(.vertical, 6)
            }
            if let notes = descriptor.userFacingNotes { SettingsNote(notes).padding(.vertical, 8) }
        }
        .task(id: draft.id) { refreshKey() }
    }

    @ViewBuilder private var appleStatus: some View {
        if let why = AppleIntelligence.availability.reason {
            SettingsStatusLine(kind: .failure, text: why)
        } else {
            SettingsStatusLine(kind: .success, text: "Ready. Runs on this Mac, no key required.")
        }
    }

    private var baseURLRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            AIInsetField(title: "Base URL", text: fieldBinding(.baseURL, \.baseURL), prompt: descriptor.defaultBaseURL)
                .disabled(locked(.baseURL))
                .settingsRow("ai.endpoint")
            switch AIProviderSettingsLogic.urlFeedback(raw: effectiveDraft.baseURL, descriptor: descriptor) {
            case .none: EmptyView()
            case .warning(let text): SettingsStatusLine(kind: .warning, text: text)
            case .error(let text): SettingsStatusLine(kind: .failure, text: text)
            }
        }
    }

    private var modelRow: some View {
        HStack(alignment: .bottom) {
            AIInsetField(title: "Model", text: fieldBinding(.model, \.model), prompt: descriptor.defaultModel ?? "Model id")
                .disabled(locked(.model))
                .settingsRow("ai.model")
            Button("Choose model\u{2026}") {
                ModelBrowserWindowController.shared.present(providerID: draft.id, currentModel: draft.model) { picked in
                    draft.model = picked
                }
            }
            .disabled(locked(.model))
            .frame(minHeight: 32)
            .padding(.bottom, 8)
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSecretField(typeLabel: "API key", prompt: placeholder, text: keyBinding)
                .settingsRow("ai.key")
            HStack(spacing: 8) {
                Button("Save key") { saveKey() }.disabled(keyDraft.isEmpty)
                Button("Clear") {
                    if model.saveKey("", for: draft.id) { model.keyDrafts[draft.id] = nil }
                    refreshKey()
                }
                keyLine
            }
            if descriptor.apiKeyOptional || !descriptor.requiresAPIKey {
                SettingsNote("An API key is optional for this provider.")
            }
        }
        .padding(.vertical, 8)
    }

    private var placeholder: String { keyStatus == .stored ? "Stored. Paste to replace" : "Paste, then Save" }

    @ViewBuilder private var keyLine: some View {
        if case .denied = keyStatus {
            SettingsStatusLine(kind: .failure, text: "Keychain access denied")
            Button("Retry") { keyError = false; refreshKey() }
        } else if keyError {
            SettingsStatusLine(kind: .failure, text: "Could not save to Keychain. Your entry was kept; try again.")
        } else {
            switch keyStatus {
            case .stored: SettingsStatusLine(kind: .success, text: "Key stored in Keychain.")
            case .missing: SettingsStatusLine(kind: .neutral, text: "No key saved.")
            case .denied: EmptyView()
            }
        }
    }

    private func refreshKey() { keyStatus = model.keyStatus(for: draft.id) }

    private func saveKey() {
        keyError = !model.saveKey(keyDraft, for: draft.id)
        if !keyError { model.keyDrafts[draft.id] = nil }
        refreshKey()
    }
}
