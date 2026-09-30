import SwiftUI

struct AIProviderAdvancedSection: View {
    @ObservedObject var model: AIProviderManagerModel
    @Binding var draft: ProviderInstance
    let descriptor: ProviderDescriptor
    @Environment(\.clippyTokens) private var tokens
    #if DEBUG
    @State private var expanded = ProcessInfo.processInfo.environment["CLIPPY_AI_SHOW_ADVANCED"] == "1"
    #else
    @State private var expanded = false
    #endif

    var body: some View {
        PaneSection("Advanced") {
            DisclosureGroup("Headers, request body and generation", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                AIProviderHeadersEditor(model: model, draft: $draft, descriptor: descriptor)
                Text("Extra body JSON").font(.headline)
                TextEditor(text: $draft.extraBodyJSON)
                    .font(.system(.body, design: .monospaced)).frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous).stroke(tokens.stroke, lineWidth: 1))
                    .settingsRow("ai.body")
                if let issue = AIProviderSettingsLogic.extraBodyIssue(draft.extraBodyJSON) {
                    SettingsStatusLine(kind: .failure, text: issue)
                }
                SettingsNote("A JSON object merged into the request body.")
                if AIProviderSettingsLogic.supports(.temperature, for: descriptor) {
                    AIOptionalNumberField(title: "Temperature", value: $draft.params.temperature, range: 0...2)
                }
                AIOptionalNumberField(title: "Max tokens", value: Binding(
                    get: { draft.params.maxTokens.map(Double.init) },
                    set: { draft.params.maxTokens = $0.map { Int($0) } }
                ), range: 1...1_000_000, integerOnly: true)
                AIOptionalNumberField(title: "Top P", value: $draft.params.topP, range: 0...1)
                if AIProviderSettingsLogic.supports(.reasoningEffort, for: descriptor) {
                    Picker("Reasoning effort", selection: Binding(get: { draft.params.reasoningEffort ?? "" }, set: { draft.params.reasoningEffort = $0.isEmpty ? nil : $0 })) {
                        Text("Provider default").tag("")
                        ForEach(AIProviderSettingsLogic.reasoningEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                if AIProviderSettingsLogic.supports(.thinkOllama, for: descriptor) {
                    Picker("Ollama think", selection: Binding(get: { draft.params.thinkOllama.map { $0 ? "on" : "off" } ?? "" }, set: { draft.params.thinkOllama = $0.isEmpty ? nil : $0 == "on" })) {
                        Text("Provider default").tag("")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                }
                timeout("First token timeout (seconds)", value: $draft.firstTokenTimeout)
                timeout("Idle timeout (seconds)", value: $draft.idleTimeout)
                timeout("Request timeout (seconds)", value: $draft.requestTimeout)
                Button("Reset to defaults") {
                    draft.headers = []
                    draft.extraBodyJSON = ""
                    draft.params = GenerationParams()
                    draft.firstTokenTimeout = ProviderInstance.defaultFirstTokenTimeout
                    draft.idleTimeout = ProviderInstance.defaultIdleTimeout
                    draft.requestTimeout = ProviderInstance.defaultRequestTimeout
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }.settingsRow("ai.advanced")
        }
    }

    private func timeout(_ label: String, value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .number)
            .onChange(of: value.wrappedValue) { _, number in
                value.wrappedValue = min(3600, max(1, number))
            }
    }
}
