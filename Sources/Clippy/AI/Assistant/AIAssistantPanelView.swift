import SwiftUI

// MARK: - Main view

/// The AI Assistant pane shown when `.assistant` is selected in the sidebar.
/// Injects the design-system environment, then hosts `AssistantPanelBody`.
struct AIAssistantPanelView: View {
    @ObservedObject var store: ClipStore
    /// The clip selected when the panel was opened (or re-selected while open).
    /// Offered as an explicit attach chip; never attached automatically (AI-03).
    var contextClip: Clip? = nil
    let onOpenSettings: () -> Void

    var body: some View {
        AssistantPanelBody(store: store, contextClip: contextClip, onOpenSettings: onOpenSettings)
            .clippyDesignSystem()
    }
}

/// Header, transcript, banners, confirmation overlay and composer.
struct AssistantPanelBody: View {
    @ObservedObject var store: ClipStore
    var contextClip: Clip?
    let onOpenSettings: () -> Void

    @StateObject var viewModel = AIAssistantViewModel()
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.clippyTokens) var tokens
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @FocusState var inputFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                AssistantHeaderView(
                    viewModel: viewModel,
                    capabilities: AssistantCapabilities(codeExecution: settings.aiAgentAllowCodeExecution,
                                                        scripts: settings.aiAgentAllowScripts,
                                                        webSearch: settings.aiAgentAllowWebSearch),
                    onOpenSettings: onOpenSettings)
                if !viewModel.toolsSupported { AssistantNoToolsBanner(providerName: viewModel.env.providerName()) }
                content
                Divider().overlay(tokens.stroke)
                inputBar
            }
            .background(tokens.surface)
            // Closing the panel cancels the turn and denies any pending confirmation (AI-08).
            .onAppear { viewModel.refreshTools() }
            .onDisappear { viewModel.stop() }
            .onChange(of: viewModel.state) { oldState, newState in
                if oldState != .streaming && newState == .streaming {
                    AccessibilityNotification.Announcement("Assistant is responding").post()
                } else if oldState == .streaming && newState != .streaming {
                    AccessibilityNotification.Announcement(AssistantPresentation.completionAnnouncement(for: viewModel.messages.last)).post()
                }
            }
            // Esc stops a running reply (the confirmation card handles its own Esc).
            .onExitCommand { if viewModel.state == .streaming { viewModel.stop() } }
            if let confirmation = viewModel.pendingConfirmation {
                tokens.surface.opacity(0.75).ignoresSafeArea().onTapGesture { viewModel.cancelPendingConfirmation() }
                    .transition(.opacity)
                AssistantConfirmationCard(
                    toolName: confirmation.toolName, prompt: confirmation.detail,
                    onAllow: { viewModel.resolveConfirmation(true) },
                    onDeny: { viewModel.resolveConfirmation(false) })
                    .padding(tokens.metrics.space.six)
                    .transition(.opacity)
            }
        }
        .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: viewModel.pendingConfirmation?.id)
        // Keep the composer ready after a confirmation closes or the conversation is cleared.
        .onChange(of: viewModel.pendingConfirmation == nil) { _, resolved in if resolved { inputFocused = true } }
        .onChange(of: viewModel.messages.isEmpty) { _, _ in inputFocused = true }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !settings.aiEnabled {
            notConfigured(title: "AI features are turned off", message: "Turn them on in Settings > AI to use the assistant.")
        } else if case .notConfigured(let reason) = viewModel.state {
            notConfigured(title: "Assistant is not set up", message: reason)
        } else if viewModel.messages.isEmpty {
            AssistantEmptyView(toolsSupported: viewModel.toolsSupported, hasAttachedClip: viewModel.contextClip != nil) { prompt in
                // Fill and send in one tap so the prompt is not left waiting in the field.
                viewModel.inputText = prompt
                if viewModel.state == .ready { viewModel.send() }
            }
        } else {
            messageThread
        }
    }

    private func notConfigured(title: String, message: String) -> some View {
        EmptyState(systemImage: "sparkles.slash", title: title, message: message,
                   actionTitle: "Open Settings", action: onOpenSettings)
            .background(tokens.surface)
    }

    // MARK: Transcript

    private var messageThread: some View {
        let positions = AssistantPresentation.groupPositions(viewModel.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.messages) { message in
                        // The empty trailing placeholder is replaced by the bubble's own shimmer.
                        AssistantMessageBubble(
                            message: message,
                            isLive: viewModel.state == .streaming && message.id == viewModel.messages.last?.id && message.role == .assistant,
                            position: positions[message.id] ?? .single,
                            onRetry: message.isError ? { viewModel.retryTurn(forError: message.id) } : nil,
                            onSaveAsClip: { store.saveScriptOutput($0) })
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(tokens.metrics.space.three)
            }
            .background(tokens.surface)
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(ClippyMotion.animation(.quick, reduce: reduceMotion)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: viewModel.state) { _, newState in
                if newState == .streaming { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // The live bubble mutates its text without changing count/state; scroll unanimated on
            // each throttled flush so animations do not restart per token.
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                if viewModel.state == .streaming { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

#Preview("Assistant") {
    AIAssistantPanelView(store: ClipStore(database: ClipDatabase.shared), onOpenSettings: {})
        .frame(width: 520, height: 640)
}
