import SwiftUI
import MarkdownUI

// MARK: - Message model

/// One turn in the assistant conversation.
struct AssistantMessage: Identifiable {
    enum Role { case user, assistant }
    /// Inline tool activity shown below the last assistant bubble while
    /// the agent is still running.
    enum ToolActivity: Equatable {
        case running(String)   // tool name currently executing
        case done(String)      // "Ran search_clips"
    }

    let id = UUID()
    let role: Role
    var text: String
    /// When true this assistant message carries an error, not a normal reply.
    var isError: Bool = false
    /// Tool activity notices attached to this message (assistant turns only).
    var toolActivities: [ToolActivity] = []
}

// MARK: - View model

/// Drives one agentic conversation. Lives for the panel session; discarded
/// when the panel closes (persistence is intentionally out of scope for v1).
@MainActor
final class AIAssistantViewModel: ObservableObject {
    enum State: Equatable { case ready, streaming, notConfigured(String) }

    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var state: State = .ready
    @Published var inputText: String = ""

    /// The in-flight streaming turn, so it can be cancelled by `stop()`.
    private var runningTask: Task<Void, Never>?

    // Confirmation sheet state
    @Published var pendingConfirmation: PendingConfirmation?

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let prompt: String
        var continuation: CheckedContinuation<Bool, Never>?
    }

    /// Kick off a user turn. Builds the provider from current settings,
    /// dispatches to the agent loop, feeds replies back to `messages`.
    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Audit [HIGH]: validate config BEFORE clearing the prompt so a
        // misconfigured provider does not discard the user's typed text.
        switch AIService.fromSettings() {
        case .failure(let err):
            state = .notConfigured(err.localizedDescription)
            return
        case .success:
            break
        }
        inputText = ""

        let settings = AppSettings.shared
        // Build an AIAgentProvider from the same settings used by AIService.
        let kind = settings.aiProvider
        let base = settings.aiBaseURL.isEmpty ? kind.defaultBaseURL : settings.aiBaseURL
        let model = settings.aiModel.isEmpty ? kind.defaultModel : settings.aiModel
        var apiKey = ""
        if kind.needsAPIKey {
            apiKey = KeychainStore.shared.read(account: kind.keychainAccount) ?? ""
        }
        let config = AIProviderConfig(
            baseURL: base, apiKey: apiKey, model: model,
            apiVersion: settings.aiAzureAPIVersion
        )
        let provider = AIAgentProviderFactory.make(kind: kind, config: config)

        // Append the user turn.
        messages.append(AssistantMessage(role: .user, text: text))
        state = .streaming

        let userMessage = AssistantMessage(role: .assistant, text: "")
        messages.append(userMessage)
        let assistantIndex = messages.count - 1

        let history = buildHistory()

        let registry = AIToolRegistry.makeFiltered(
            allowScripts: settings.aiAgentAllowScripts,
            allowCodeExecution: settings.aiAgentAllowCodeExecution,
            allowWebSearch: settings.aiAgentAllowWebSearch,
            confirmHook: { [weak self] prompt in
                guard let self else { return false }
                return await self.askConfirmation(prompt)
            }
        )

        // Diagnostic breadcrumb: records which endpoint/model the turn targets
        // (never the key) so a failed turn can be traced from the log alone.
        ClippyLog.debug(
            "AI send: provider=\(String(describing: kind)) model=\(model) base=\(base) tools=\(registry.all.count) history=\(history.count)",
            category: ClippyLog.ai)

        runningTask = Task { [weak self] in
            guard let self else { return }
            defer { self.state = .ready; self.runningTask = nil }   // ALWAYS resets, kills the freeze class
            var buffer = ""
            var lastFlush = Date()
            var eventCount = 0
            // Local closure rather than a nested func so it inherits the
            // enclosing Task's main-actor isolation and may mutate `messages`.
            let flush = { @MainActor in
                guard !buffer.isEmpty else { return }
                self.messages[assistantIndex].text += buffer
                buffer = ""
                lastFlush = Date()
            }
            do {
                for try await event in AIAgent.streamWithTools(messages: history, provider: provider, tools: registry.all) {
                    if Task.isCancelled { break }
                    eventCount += 1
                    switch event {
                    case .textDelta(let t):
                        buffer += t
                        if Date().timeIntervalSince(lastFlush) > 0.05 { flush() }   // ~20fps coalesce
                    case .toolStarted(let name):
                        flush()
                        self.messages[assistantIndex].toolActivities.append(.running(name))
                    case .toolFinished(let name):
                        if let i = self.messages[assistantIndex].toolActivities.firstIndex(of: .running(name)) {
                            self.messages[assistantIndex].toolActivities[i] = .done(name)
                        }
                    }
                }
                flush()
                // Fail loud: a stream that ends without producing any text or tool
                // activity must not leave a blank bubble. A clean (non-throwing)
                // completion with zero output is itself a failure the user needs to
                // see, so surface a diagnostic instead of silence.
                if !Task.isCancelled
                    && self.messages[assistantIndex].text.isEmpty
                    && self.messages[assistantIndex].toolActivities.isEmpty {
                    ClippyLog.error(
                        "AI stream produced no output (events=\(eventCount), provider=\(String(describing: kind)), model=\(model))",
                        category: ClippyLog.ai)
                    self.messages[assistantIndex].text = "The assistant returned an empty response. Check that the model name is correct and that the provider supports streaming, then try again."
                    self.messages[assistantIndex].isError = true
                }
            } catch is CancellationError {
                flush()
            } catch {
                flush()
                ClippyLog.error("AI agent error: \(error)", category: ClippyLog.ai)
                if self.messages[assistantIndex].text.isEmpty {
                    self.messages[assistantIndex].text = error.localizedDescription
                    self.messages[assistantIndex].isError = true
                }
            }
        }
    }

    func clearConversation() { stop(); messages = []; state = .ready; inputText = "" }

    // MARK: - Retry

    /// Re-send the user turn that preceded an error bubble (audit [HIGH]/[LOW]).
    /// Drops the failed assistant bubble (and anything after the preceding user
    /// message) so the transcript does not accumulate duplicate error rows.
    func retryTurn(forError errorId: UUID) {
        guard let errorIdx = messages.firstIndex(where: { $0.id == errorId }) else { return }
        // Find the user message immediately before the error bubble.
        let prefix = messages.prefix(errorIdx)
        guard let userIdx = prefix.lastIndex(where: { $0.role == .user }) else { return }
        let text = messages[userIdx].text
        // Trim from the preceding user message onward, then re-send.
        messages = Array(messages.prefix(userIdx))
        inputText = text
        send()
    }

    // MARK: - Confirmation

    /// Present a confirmation sheet and suspend until the user responds.
    private func askConfirmation(_ prompt: String) async -> Bool {
        await withCheckedContinuation { cont in
            pendingConfirmation = PendingConfirmation(
                prompt: prompt,
                continuation: cont
            )
        }
    }

    func resolveConfirmation(_ allowed: Bool) {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil                       // clear FIRST so re-entry is a no-op
        confirmation.continuation?.resume(returning: allowed)
    }

    func cancelPendingConfirmation() { resolveConfirmation(false) }

    func stop() {
        cancelPendingConfirmation()
        runningTask?.cancel()
        runningTask = nil
        // Audit [MEDIUM, bug]: reset state right away so a wedged stream does not
        // strand the UI in .streaming. The running task's `defer` is a backstop.
        if case .streaming = state { state = .ready }
    }

    // MARK: - Helpers

    private func buildHistory() -> [AIMessage] {
        messages.compactMap { msg -> AIMessage? in
            if msg.role == .user {
                return AIMessage(role: .user, content: msg.text)
            }
            // Assistant turn: keep text-bearing turns. Tool-only turns (empty
            // text but tool activities) are serialized as a stub so the model
            // retains what it already did on the next send (audit [LOW]).
            if !msg.text.isEmpty {
                return AIMessage(role: .assistant, content: msg.text)
            }
            if !msg.toolActivities.isEmpty {
                let stub = msg.toolActivities.map { activity -> String in
                    switch activity {
                    case .running(let name): return "Running \(name)"
                    case .done(let name): return "Ran \(name)"
                    }
                }.joined(separator: "\n")
                return AIMessage(role: .assistant, content: stub)
            }
            // Skip empty trailing assistant placeholder.
            return nil
        }
    }
}

// MARK: - Main view

/// The AI Assistant pane shown when `.assistant` is selected in the sidebar.
struct AIAssistantPanelView: View {
    @ObservedObject var store: ClipStore
    let onOpenSettings: () -> Void

    @StateObject private var vm = AIAssistantViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var confirmClear = false

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                inputBar
            }
            // Audit [LOW]: announce turn start/finish to VoiceOver so a user
            // relying on accessibility knows when the assistant begins and ends.
            .onChange(of: vm.state) { oldState, newState in
                if oldState != .streaming && newState == .streaming {
                    AccessibilityNotification.Announcement("Assistant is responding").post()
                } else if oldState == .streaming && newState != .streaming {
                    AccessibilityNotification.Announcement("Assistant finished responding").post()
                }
            }
            if let confirmation = vm.pendingConfirmation {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { vm.cancelPendingConfirmation() }
                InlineConfirmationCard(
                    prompt: confirmation.prompt,
                    tokens: tokens, settings: settings,
                    onAllow: { vm.resolveConfirmation(true) },
                    onDeny: { vm.resolveConfirmation(false) }
                )
                .padding(24)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.accent)
                // Shimmer the mark while the assistant is generating a reply.
                .symbolEffect(.variableColor, isActive: !reduceMotion && vm.state == .streaming)
            Text("AI Assistant")
                .font(PanelTypography.body(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
            Spacer()
            if !vm.messages.isEmpty {
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tokens.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
                .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { vm.clearConversation() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All messages will be removed and cannot be recovered.")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !settings.aiEnabled {
            notConfiguredState(
                icon: "sparkles.slash",
                message: "AI features are turned off.",
                cta: "Open Settings"
            )
        } else if case .notConfigured(let reason) = vm.state {
            notConfiguredState(icon: "exclamationmark.triangle", message: reason, cta: "Open Settings")
        } else if vm.messages.isEmpty {
            emptyState
        } else {
            messageThread
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.textSecondary)
                Text("Ask the assistant anything about your clips, or ask it to create, search, or transform content.")
                    .font(PanelTypography.body(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 8) {
                    suggestionButton("Search my clips for meeting notes")
                    suggestionButton("Create a clip with a bash one-liner to list files")
                    suggestionButton("Summarize what I copied today")
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(tokens.scrollBackground.opacity(settings.panelOpacity))
    }

    private func suggestionButton(_ text: String) -> some View {
        Button {
            // Audit [LOW]: fill and send in one tap instead of leaving the
            // prompt sitting in the field waiting for a second action.
            vm.inputText = text
            if vm.state == .ready { vm.send() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.accent)
                Text(text)
                    .font(PanelTypography.body(settings))
                    .foregroundStyle(tokens.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tokens.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var messageThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { message in
                        // Audit [MEDIUM]: suppress the empty trailing assistant
                        // placeholder while the thinking indicator is showing so
                        // the user does not see an empty bubble next to the spinner.
                        if showsEmptyPlaceholder(message) {
                            EmptyView()
                                .id(message.id)
                        } else {
                            MessageBubble(
                                message: message,
                                tokens: tokens,
                                settings: settings,
                                isLive: vm.state == .streaming
                                    && message.id == vm.messages.last?.id
                                    && message.role == .assistant,
                                onRetry: message.isError
                                    ? { vm.retryTurn(forError: message.id) }
                                    : nil
                            )
                                .id(message.id)
                        }
                    }
                    if showThinkingIndicator {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(10)
            }
            .background(tokens.scrollBackground.opacity(settings.panelOpacity))
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.state) { _, newState in
                if newState == .streaming {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
            // Audit [HIGH]: the live bubble mutates `messages.last.text` without
            // changing count/state, so scroll on text change too. Throttled by
            // the ~50ms flush cadence in send(); debounce slightly to stay smooth.
            .onChange(of: vm.messages.last?.text) { _, _ in
                guard vm.state == .streaming, let last = vm.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// True when `message` is the live empty assistant placeholder that should be
    /// hidden in favour of the thinking indicator.
    private func showsEmptyPlaceholder(_ message: AssistantMessage) -> Bool {
        showThinkingIndicator
            && message.role == .assistant
            && message.id == vm.messages.last?.id
            && message.text.isEmpty
            && message.toolActivities.isEmpty
    }

    /// Show the typing indicator only while streaming AND before the first
    /// token lands in the live assistant bubble, so it disappears once text arrives.
    private var showThinkingIndicator: Bool {
        vm.state == .streaming && (vm.messages.last?.text.isEmpty ?? false)
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking...")
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        // Audit [LOW]: label the indicator for VoiceOver users.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Assistant is thinking")
    }

    private func notConfiguredState(icon: String, message: String, cta: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
            Text(message)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button(cta) { onOpenSettings() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.scrollBackground.opacity(settings.panelOpacity))
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything...", text: $vm.inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
                .focused($inputFocused)
                .accessibilityLabel("Message input")
                .onSubmit {
                    if !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && vm.state == .ready {
                        vm.send()
                    }
                }
                .onAppear { inputFocused = true }
            Button {
                if vm.state == .streaming { vm.stop() } else { vm.send() }
            } label: {
                Image(systemName: vm.state == .streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        vm.state == .streaming ? tokens.accent
                        : (vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tokens.textSecondary : tokens.accent))
                    // Swap send <-> stop as a symbol replace when streaming starts/ends.
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            // Audit [LOW]: Cmd+Return submits from the multi-line field where
            // plain Return inserts a newline; also surfaces the hint as a tooltip.
            .keyboardShortcut(.return, modifiers: .command)
            .help(vm.state == .streaming ? "Stop" : "Send (Cmd-Return)")
            .accessibilityLabel(vm.state == .streaming ? "Stop" : "Send")
            .disabled(vm.state != .streaming && vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: AssistantMessage
    let tokens: ThemeTokens
    let settings: AppSettings
    let isLive: Bool
    /// Re-send the preceding user message when the user activates Retry on an
    /// error bubble (audit [HIGH]). nil for non-error bubbles.
    let onRetry: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer(minLength: 40) }
                // The bubble wraps the content plus, for assistant turns, the
                // per-tool step list so progress reads inside the bubble while
                // the agent streams (audit [POLISH]/[MEDIUM]).
                VStack(alignment: .leading, spacing: 6) {
                    // Error messages show a warning glyph prefix and use danger color.
                    Group {
                        if message.isError {
                            Label {
                                Text(message.text.isEmpty ? " " : message.text)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.hierarchical)
                            }
                                .font(PanelTypography.body(settings))
                                .foregroundStyle(tokens.danger)
                        } else if message.role == .assistant {
                            // While a turn is streaming, render plain Text: re-parsing the
                            // whole markdown string on every flush saturates the main thread.
                            // Swap to Markdown once the turn is done (isLive == false).
                            if isLive {
                                // Selectable while streaming, but via our own read-only NSTextView
                                // (not SwiftUI's .textSelection). SwiftUI's SelectionOverlay re-runs
                                // AppKit text layout per token and re-enters the view-graph transaction
                                // without converging (100% CPU, runaway memory). An NSTextView lays out
                                // in AppKit and only re-measures once per token, so it stays flat.
                                StreamingSelectableText(
                                    text: message.text.isEmpty ? " " : message.text,
                                    font: .systemFont(ofSize: CGFloat(settings.fontSizeBase)),
                                    color: NSColor(tokens.textPrimary)
                                )
                            } else {
                                Markdown(message.text.isEmpty ? " " : message.text)
                                    .markdownTheme(.clippy(tokens: tokens, settings: settings))
                            }
                        } else {
                            Text(message.text.isEmpty ? " " : message.text)
                                .font(PanelTypography.body(settings))
                                .foregroundStyle(tokens.isDark ? Color.white : Color(nsColor: .labelColor).opacity(0.9))
                        }
                    }
                    // Tool activity step list lives inside the bubble for assistant
                    // turns (audit [POLISH]). Empty for user/error turns.
                    if message.role == .assistant {
                        ForEach(Array(message.toolActivities.enumerated()), id: \.offset) { _, activity in
                            toolActivityLabel(activity)
                        }
                    }
                }
                // Audit [MEDIUM]: selection during streaming is provided by the
                // read-only NSTextView above (SwiftUI's .textSelection re-runs AppKit
                // layout per token). SwiftUI text selection stays on for static bubbles.
                .textSelectionEnabled(!isLive)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    message.role == .user
                        ? tokens.accent
                        : (message.isError ? tokens.danger.opacity(0.08) : tokens.cardSurface),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            message.isError ? tokens.danger.opacity(0.4)
                                : (message.role == .user ? Color.clear : tokens.cardBorder),
                            lineWidth: 1
                        )
                )
                // Audit [LOW]: combine the bubble's children into one accessible
                // element with a "You: ..." / "Assistant: ..." / "Error: ..." label.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
                if message.role == .assistant { Spacer(minLength: 40) }
            }
            // Audit [HIGH]: Retry CTA under error bubbles, re-sending the
            // preceding user message. Lives outside the bubble background.
            if message.isError, let onRetry = onRetry {
                HStack {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(PanelTypography.metadata(settings))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Retry sending the last message")
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// VoiceOver-friendly description of the bubble contents.
    private var accessibilityText: String {
        if message.isError { return "Error: \(message.text)" }
        switch message.role {
        case .user:      return "You: \(message.text)"
        case .assistant:  return "Assistant: \(message.text)"
        }
    }

    private func toolActivityLabel(_ activity: AssistantMessage.ToolActivity) -> some View {
        let (icon, label, isRunning): (String, String, Bool) = {
            switch activity {
            case .running(let name): return ("gear", "Running \(name)...", true)
            case .done(let name):    return ("checkmark.circle", "Ran \(name)", false)
            }
        }()
        return Label {
            Text(label)
        } icon: {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                // Spin the gear while a tool runs; the finished checkmark is static.
                .symbolEffect(.variableColor, isActive: !reduceMotion && isRunning)
        }
            .font(PanelTypography.metadata(settings))
            .foregroundStyle(isRunning ? tokens.accent : tokens.textSecondary)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
    }
}

// MARK: - Inline confirmation card

/// Shown as an overlay when the agent wants to run a gated tool (run_script,
/// execute_code). The user sees the full prompt before deciding.
private struct InlineConfirmationCard: View {
    let prompt: String
    let tokens: ThemeTokens
    let settings: AppSettings
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Confirm action")
                    .foregroundStyle(tokens.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.shield")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tokens.danger, tokens.textSecondary)
            }
                .font(PanelTypography.body(settings).weight(.semibold))
            Text("The assistant wants to run this. Review before allowing.")
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
            ScrollView {
                Text(prompt)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))
            HStack {
                // Audit [MEDIUM]: for code-executing tools the safe choice (Deny)
                // is the default Return action; Allow needs an explicit click or
                // Cmd-Return so a stray Enter does not approve a destructive tool.
                Button("Deny", role: .cancel, action: onDeny)
                    .keyboardShortcut(.return, modifiers: [])
                Spacer()
                Button("Allow", action: onAllow)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Press Cmd-Return to allow")
            }
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(tokens.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tokens.cardBorder, lineWidth: 1))
        .shadow(radius: 20)
        // Escape also denies (cancel convention), in addition to Return above.
        .onExitCommand { onDeny() }
    }
}

// MARK: - Conditional text selection

private extension View {
    /// Enables text selection only when `enabled` is true. When false the view is
    /// returned unmodified so SwiftUI never installs its SelectionOverlay, keeping
    /// the rapidly-mutating streaming bubble out of the AppKit text-layout path.
    @ViewBuilder
    func textSelectionEnabled(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}

// MARK: - Streaming selectable text

/// A read-only, selectable NSTextView wrapped for SwiftUI. Used for the live
/// streaming AI bubble so its text is selectable WITHOUT SwiftUI's SelectionOverlay,
/// which re-enters the view-graph transaction per token and never converges.
/// AppKit handles selection and lays out once per token, so it stays flat.
private struct StreamingSelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor

    func makeNSView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        // Hug content vertically and let the container set the width so text wraps.
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: SelfSizingTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.font = font
        tv.textColor = color
        // One re-measure per token; no SwiftUI selection overlay is involved.
        tv.invalidateIntrinsicContentSize()
    }
}

/// NSTextView that reports its laid-out height as intrinsic content size so SwiftUI
/// can size the bubble to the text. Width is driven by the SwiftUI container.
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }
}
