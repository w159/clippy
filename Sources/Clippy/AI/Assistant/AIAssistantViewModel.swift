import Foundation
import SwiftUI

/// Drives one agentic conversation. Display messages are addressed by id, never
/// by index, so clearing or retrying while a reply streams cannot trap (AI-01);
/// what the model sees is the structured `AITranscript` (AI-05).
@MainActor
final class AIAssistantViewModel: ObservableObject {
    enum State: Equatable { case ready, streaming, notConfigured(String) }

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let toolName: String
        /// The complete call, never truncated (AI-07).
        let detail: String
        var continuation: CheckedContinuation<Bool, Never>?
    }

    /// One row of the tool drawer.
    struct ToolInfo: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let description: String
        var policy: AIToolPolicy
    }

    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var state: State = .ready
    @Published var inputText: String = ""
    /// The clip the user explicitly attached (AI-03). Never set automatically.
    @Published var contextClip: Clip?
    @Published var pendingConfirmation: PendingConfirmation?
    /// Tools the model is offered, with policies, for the drawer.
    @Published private(set) var toolInfos: [ToolInfo] = []
    @Published private(set) var toolsSupported = true

    let env: AIAssistantEnvironment
    private(set) var transcript = AITranscript()
    private var runningTask: Task<Void, Never>?
    /// Identifies the live turn. A stale task (cleared or superseded) sees a
    /// different token and stops touching shared state.
    private var turnToken = UUID()

    init(env: AIAssistantEnvironment = .live()) {
        self.env = env
        if let snapshot = env.conversationStore?.load() {
            messages = snapshot.messages.map { msg in
                var copy = msg
                for step in copy.toolSteps.indices { copy.toolSteps[step].isRunning = false }
                return copy
            }
            transcript = snapshot.transcript
        }
        refreshTools()
    }

    /// Recompute provider capability and the tool list (settings may have changed).
    func refreshTools() {
        toolsSupported = env.supportsTools()
        toolInfos = toolsSupported
            ? env.baseTools().sorted { $0.name < $1.name }.map {
                ToolInfo(name: $0.name, description: $0.description, policy: env.policyStore.policy(for: $0.name))
            }
            : []
    }

    func setPolicy(_ policy: AIToolPolicy, for toolName: String) {
        env.policyStore.set(policy, for: toolName)
        refreshTools()
    }

    /// Token usage summed over the whole conversation, when providers reported it.
    var totalUsage: AIUsage { messages.compactMap(\.usage).reduce(AIUsage(), +) }

    // MARK: - Sending

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .streaming else { return }
        // Audit [HIGH]: validate config BEFORE clearing the prompt so a
        // misconfigured provider does not discard the user's typed text.
        let provider: AIAgentProvider
        switch env.makeProvider() {
        case .failure(let err):
            state = .notConfigured(err.localizedDescription)
            return
        case .success(let made):
            provider = made
        }
        inputText = ""
        refreshTools()

        let turnStart = transcript.count
        transcript.append(.user(text))
        let assistant = AssistantMessage(role: .assistant, text: "")
        messages.append(AssistantMessage(role: .user, text: text, transcriptStart: turnStart))
        messages.append(assistant)
        state = .streaming
        let token = UUID()
        turnToken = token

        var history = transcript.providerMessages()
        if let clip = contextClip {
            history.insert(AIMessage(role: .system, content: Self.preamble(for: clip)), at: 0)
        }
        let confirm: (String, String) async -> Bool = { [weak self] name, detail in
            guard let self else { return false }
            let allowed = await self.askConfirmation(toolName: name, detail: detail)
            if !allowed { AuditedTool.recordDenied(tool: name) }
            return allowed
        }
        let tools = toolsSupported
            ? AIToolPolicy.apply(
                to: AssistantSandboxHooks.audited(AssistantSandboxHooks.bind(env.baseTools(), confirm: confirm)),
                store: env.policyStore, confirm: confirm)
            : []

        runningTask = Task { [weak self] in
            await self?.runTurn(assistantID: assistant.id, turnStart: turnStart, history: history,
                                provider: provider, tools: tools, token: token)
        }
    }

    /// System preamble carrying the attached clip so "this clip" questions work.
    static func preamble(for clip: Clip) -> String {
        let idPart = clip.id.map { " (clip id \($0))" } ?? ""
        return """
        The user attached a clipboard item\(idPart) titled "\(clip.displayTitle)" as context. \
        When they say "this clip" or "the clip", they mean this item. Its content:

        \(AIService.clamp(clip.contentText, 4000))
        """
    }

    /// Await the in-flight turn (tests, and callers that must sequence after it).
    func waitForTurn() async { await runningTask?.value }

    // MARK: - Turn execution

    private func isCurrent(_ token: UUID) -> Bool { turnToken == token }

    private func update(_ id: UUID, _ body: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        body(&messages[index])
    }

    private func runTurn(assistantID: UUID, turnStart: Int, history: [AIMessage],
                         provider: AIAgentProvider, tools: [AITool], token: UUID) async {
        defer {
            if isCurrent(token) {
                state = .ready
                runningTask = nil
                persist()
            }
        }
        var buffer = ""          // coalesced text not yet on the bubble
        var segment = ""         // assistant text since the last tool call
        var lastFlush = Date()
        var usage = AIUsage()
        func flush() {
            guard !buffer.isEmpty else { return }
            let chunk = buffer
            buffer = ""
            lastFlush = Date()
            update(assistantID) { $0.text += chunk }
        }
        func commitSegment() {
            if !segment.isEmpty { transcript.append(.assistant(segment)) }
            segment = ""
        }
        do {
            for try await event in AIAgent.streamWithTools(messages: history, provider: provider, tools: tools) {
                guard isCurrent(token) else { return }
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    buffer += delta
                    segment += delta
                    if Date().timeIntervalSince(lastFlush) > 0.05 { flush() }
                case .textReplace(let old, let new):
                    flush()
                    segment = AITextReplace.apply(to: segment, old: old, new: new)
                    update(assistantID) { $0.text = AITextReplace.apply(to: $0.text, old: old, new: new) }
                case .notice(let message):
                    flush()
                    update(assistantID) {
                        $0.toolSteps.append(AssistantToolStep(id: "notice-\(UUID())", name: message, isRunning: false))
                    }
                case .toolCall(let call):
                    flush()
                    commitSegment()
                    transcript.appendToolCall(call)
                    let step = AssistantToolStep(id: call.id, name: call.toolName,
                                                 arguments: Self.prettyArguments(call.arguments), isRunning: true)
                    update(assistantID) { $0.toolSteps.append(step) }
                case .toolStarted(let name):
                    flush()
                    update(assistantID) { msg in
                        if !msg.toolSteps.contains(where: { $0.name == name && $0.isRunning }) {
                            msg.toolSteps.append(AssistantToolStep(id: "label-\(UUID())", name: name, isRunning: true))
                        }
                    }
                case .toolResult(let id, let name, let result):
                    transcript.append(.toolResult(id: id, name: name, result: result))
                    update(assistantID) { msg in
                        if let step = msg.toolSteps.firstIndex(where: { $0.id == id }) { msg.toolSteps[step].result = result }
                    }
                case .toolFinished(let name):
                    update(assistantID) { msg in
                        if let step = msg.toolSteps.firstIndex(where: { $0.name == name && $0.isRunning }) {
                            msg.toolSteps[step].isRunning = false
                        }
                    }
                case .usage(let reported):
                    usage += reported
                    update(assistantID) { $0.usage = usage }
                }
            }
            guard isCurrent(token) else { return }
            flush()
            try Task.checkCancellation()
            commitSegment()
            failIfEmpty(assistantID, turnStart: turnStart)
        } catch {
            guard isCurrent(token) else { return }
            flush()
            if !(error is CancellationError) { AIHealth.shared.record(error) }
            let message = error is CancellationError ? "The request was cancelled." : error.localizedDescription
            showError(message, on: assistantID, turnStart: turnStart)
        }
    }

    /// A stream that ends with no text and no tool activity is a failure the user
    /// must see, not a blank bubble.
    private func failIfEmpty(_ id: UUID, turnStart: Int) {
        guard let msg = messages.first(where: { $0.id == id }),
              msg.text.isEmpty, msg.toolSteps.isEmpty, !Task.isCancelled else { return }
        AIHealth.shared.record(AIError.empty)
        showError("The assistant returned an empty response. Check that the model name is correct and that the provider supports streaming, then try again.",
                  on: id, turnStart: turnStart)
    }

    /// Show an error bubble. It is display-only: the failed turn is rolled back out
    /// of the transcript unless tools already ran (their side effects happened and
    /// the model should still know about them).
    private func showError(_ message: String, on id: UUID, turnStart: Int) {
        update(id) { msg in
            msg.text = msg.text.isEmpty ? message : msg.text + "\n\n[Interrupted] \(message)"
            msg.isError = true
            for index in msg.toolSteps.indices { msg.toolSteps[index].isRunning = false }
        }
        if !transcript.hasToolActivity(since: turnStart) { transcript.truncate(to: turnStart) }
    }

    static func prettyArguments(_ args: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - Clear / retry / stop

    func clearConversation() {
        stop()
        turnToken = UUID()   // any still-unwinding task is now stale
        messages = []
        transcript = AITranscript()
        state = .ready
        inputText = ""
        env.conversationStore?.clear()
    }

    /// Re-send the user turn that preceded an error bubble. Stops any live turn
    /// first, then rolls the transcript and display back to before that turn.
    func retryTurn(forError errorID: UUID) {
        stop()
        guard let errorIndex = messages.firstIndex(where: { $0.id == errorID }),
              let userIndex = messages.prefix(errorIndex).lastIndex(where: { $0.role == .user }) else { return }
        let user = messages[userIndex]
        if let start = user.transcriptStart {
            transcript.truncate(to: start)
        } else if let last = transcript.entries.lastIndex(of: .user(user.text)) {
            transcript.truncate(to: last)   // restored from disk: locate the turn by text
        }
        messages = Array(messages.prefix(userIndex))
        inputText = user.text
        send()
    }

    /// Cancel the running turn and deny any pending confirmation. Also called when
    /// the panel disappears so no task or continuation outlives the view (AI-08).
    func stop() {
        cancelPendingConfirmation()
        runningTask?.cancel()
        runningTask = nil
        if case .streaming = state { state = .ready }
    }

    // MARK: - Confirmation

    private func askConfirmation(toolName: String, detail: String) async -> Bool {
        resolveConfirmation(false)   // never strand an earlier continuation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pendingConfirmation = PendingConfirmation(toolName: toolName, detail: detail, continuation: cont)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveConfirmation(false) }
        }
    }

    func resolveConfirmation(_ allowed: Bool) {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil   // clear FIRST so re-entry is a no-op
        confirmation.continuation?.resume(returning: allowed)
    }

    func cancelPendingConfirmation() { resolveConfirmation(false) }

    // MARK: - Persistence

    private func persist() {
        guard let store = env.conversationStore else { return }
        let kept = messages.filter { !($0.role == .assistant && $0.text.isEmpty && $0.toolSteps.isEmpty) }
        store.save(AIConversationStore.Snapshot(messages: kept, transcript: transcript))
    }
}
