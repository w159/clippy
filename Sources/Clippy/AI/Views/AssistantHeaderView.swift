import SwiftUI

/// Assistant header: title, provider status, capability chip, conversation usage,
/// tool drawer and clear button. Layout collapses gracefully at compact widths.
struct AssistantHeaderView: View {
    @ObservedObject var viewModel: AIAssistantViewModel
    let capabilities: AssistantCapabilities
    let onOpenSettings: () -> Void
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false
    @State private var showTools = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: tokens.metrics.space.two) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.accentText)
                    .symbolEffect(.variableColor, isActive: !reduceMotion && viewModel.state == .streaming)
                    .accessibilityHidden(true)
                Text("AI Assistant").font(.headline).foregroundStyle(tokens.textPrimary).lineLimit(1)
                ReasonChip(title: viewModel.env.providerName(), systemImage: "cpu",
                           explanation: "Provider used for replies. Change it in Settings > AI.", action: onOpenSettings)
                AssistantCapabilityChip(capabilities: capabilities, onOpenSettings: onOpenSettings)
                Spacer(minLength: tokens.metrics.space.two)
                if let usage = AssistantPresentation.conversationUsageLabel(viewModel.totalUsage) {
                    Text(usage).font(.caption.monospacedDigit()).foregroundStyle(tokens.textSecondary)
                        .help("Tokens used in this conversation, as reported by the provider")
                        .accessibilityLabel("Conversation usage \(usage)")
                }
                IconButton("wrench.and.screwdriver", label: "Assistant tools", help: "Tools the assistant can use",
                           state: showTools ? .selected : .rest) { showTools.toggle() }
                    .popover(isPresented: $showTools) { AssistantToolDrawer(viewModel: viewModel) }
                IconButton("trash", label: "Clear conversation", help: "Clear conversation",
                           state: viewModel.messages.isEmpty ? .disabled : .rest) { confirmClear = true }
                    .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { viewModel.clearConversation() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("All messages will be removed and cannot be recovered.")
                    }
            }
            .padding(.horizontal, tokens.metrics.space.three)
            .padding(.vertical, tokens.metrics.space.two)
            Divider().overlay(tokens.stroke)
        }
        .background(tokens.surface)
    }
}

/// Persistent banner for providers that cannot call tools (AI-02).
struct AssistantNoToolsBanner: View {
    let providerName: String

    var body: some View {
        ClippyBanner("\(providerName) can chat but cannot use tools, so it cannot search, create, or categorize clips. "
            + "Attach a clip to ask about it, or choose another provider in Settings.", severity: .warning)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// Empty state with prompts the current provider can execute.
struct AssistantEmptyView: View {
    @Environment(\.clippyTokens) private var tokens
    let toolsSupported: Bool
    let hasAttachedClip: Bool
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: tokens.metrics.space.four) {
                Image(systemName: "sparkles").font(.system(size: 36, weight: .light))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(tokens.textSecondary).accessibilityHidden(true)
                Text("Ask the assistant about your clips").font(.title3.weight(.semibold)).foregroundStyle(tokens.textPrimary)
                Text("Try one of these, or type your own.").font(.callout).foregroundStyle(tokens.textSecondary)
                VStack(spacing: tokens.metrics.space.two) {
                    ForEach(AssistantPresentation.suggestions(toolsSupported: toolsSupported, hasAttachedClip: hasAttachedClip), id: \.self) { prompt in
                        Button { onPick(prompt) } label: {
                            HStack(spacing: tokens.metrics.space.two) {
                                Image(systemName: "arrow.up.circle").foregroundStyle(tokens.accentText)
                                Text(prompt).font(.body).foregroundStyle(tokens.textPrimary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, tokens.metrics.space.three)
                            .padding(.vertical, tokens.metrics.space.two)
                            .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.stroke, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ask: \(prompt)")
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(tokens.metrics.space.six)
            .frame(maxWidth: .infinity)
        }
        .background(tokens.surface)
    }
}
