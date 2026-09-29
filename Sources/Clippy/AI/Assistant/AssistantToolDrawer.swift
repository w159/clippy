import SwiftUI

/// Lists the tools the assistant can call with a per-tool policy picker (AI-07,
/// AI-12). Shows why the list is empty when the provider cannot call tools.
struct AssistantToolDrawer: View {
    @ObservedObject var viewModel: AIAssistantViewModel
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            Text("Assistant tools").font(.headline).foregroundStyle(tokens.textPrimary)
            if !viewModel.toolsSupported {
                ClippyBanner("\(viewModel.env.providerName()) cannot call tools, so none are offered.", severity: .warning)
            } else if viewModel.toolInfos.isEmpty {
                Text("No tools are enabled.").font(.callout).foregroundStyle(tokens.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
                        ForEach(viewModel.toolInfos) { info in row(info) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Text("Scripts, code execution, and web search are enabled in Settings > AI.")
                .font(.caption).foregroundStyle(tokens.textSecondary)
        }
        .padding(tokens.metrics.space.four)
        .frame(width: 360)
        .background(tokens.surfaceElevated)
    }

    private func row(_ info: AIAssistantViewModel.ToolInfo) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            HStack {
                Text(info.name).font(.system(.callout, design: .monospaced).weight(.medium)).foregroundStyle(tokens.textPrimary)
                Spacer(minLength: tokens.metrics.space.two)
                Picker("Policy", selection: Binding(get: { info.policy }, set: { viewModel.setPolicy($0, for: info.name) })) {
                    ForEach(AIToolPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
                .accessibilityLabel("Policy for \(info.name)")
            }
            Text(info.description).font(.caption).foregroundStyle(tokens.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}
