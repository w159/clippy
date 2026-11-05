import SwiftUI

/// Lists the tools the assistant can call with a per-tool policy picker (AI-07,
/// AI-12). Shows why the list is empty when the provider cannot call tools.
struct AssistantToolDrawer: View {
    var viewModel: AIAssistantViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assistant tools").font(.headline)
            if !viewModel.toolsSupported {
                ClippyBanner("\(viewModel.env.providerName()) cannot call tools, so none are offered.", severity: .warning)
            } else if viewModel.toolInfos.isEmpty {
                ContentUnavailableView("No tools are enabled", systemImage: "wrench.and.screwdriver")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.toolInfos) { info in row(info) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Text("Scripts, code execution, and web search are enabled in Settings > AI.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func row(_ info: AIAssistantViewModel.ToolInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(info.name).font(.callout.monospaced().weight(.medium))
                Spacer(minLength: 8)
                Picker("Policy", selection: Binding(get: { info.policy }, set: { viewModel.setPolicy($0, for: info.name) })) {
                    ForEach(AIToolPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
                .accessibilityLabel("Policy for \(info.name)")
            }
            Text(info.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
