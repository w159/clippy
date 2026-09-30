import Foundation

// MARK: - Agent loop

/// Drives an agentic conversation: sends messages, receives tool calls, executes
/// them (with confirmation), feeds results back, and loops until the model
/// returns plain text or `maxRounds` is exhausted.
enum AIAgent {
    /// Maximum tool-call rounds before the loop gives up.
    static let maxRounds = 8

    /// Run the agent loop.
    ///
    /// - Parameters:
    ///   - messages:  Initial conversation messages.
    ///   - provider:  An `AIAgentProvider` (wraps a real or mock backend).
    ///   - tools:     Tools available to the model. Individual tools that require
    ///                confirmation (RunScriptTool, ExecuteCodeTool) carry their own
    ///                `confirmHook`; there is no separate gate at the agent-loop level.
    ///   - options:   Temperature / maxTokens forwarded to each provider call.
    /// - Returns: The model's final text answer.
    static func completeWithTools(
        messages initialMessages: [AIMessage],
        provider: AIAgentProvider,
        tools: [AITool],
        options: AICompletionOptions = AICompletionOptions()
    ) async throws -> String {
        var messages = initialMessages
        var round = 0

        while round < maxRounds {
            round += 1
            let turn = try await provider.completeWithTools(messages, tools: tools, options: options)

            switch turn {
            case .text(let answer):
                return answer

            case .toolCalls(let calls):
                // Append the assistant's tool-call turn so the history is complete.
                let assistantMsg = AIMessage(role: .assistant,
                                            content: AIToolCallsSentinel.encode(calls))
                messages.append(assistantMsg)

                // Execute each call and accumulate result messages.
                for call in calls {
                    let result: String
                    if let tool = tools.first(where: { $0.name == call.toolName }) {
                        do {
                            // Each tool is responsible for calling the confirm hook
                            // when it requires confirmation (run_script, execute_code).
                            result = try await tool.execute(args: call.arguments)
                        } catch {
                            // Log so operators can diagnose silently-failing tools;
                            // the model still receives the error string so it can report back.
                            ClippyLog.error("Tool \"\(call.toolName)\" failed: \(error)", category: ClippyLog.ai)
                            result = "Tool error: \(error.localizedDescription)"
                        }
                    } else {
                        result = "Error: unknown tool \"\(call.toolName)\"."
                    }

                    // Append the tool result as a user message. Different providers
                    // expect different roles; the concrete providers decode this
                    // sentinel and reformat it in their own wire shape.
                    messages.append(AIMessage(
                        role: .user,
                        content: AIToolResultSentinel.encode(id: call.id, toolName: call.toolName, result: result)
                    ))
                }
            }
        }

        // Exhausted rounds — ask for a summary of what was done.
        messages.append(AIMessage(role: .user,
                                  content: "Summarise what you accomplished with the tools."))
        return try await provider.complete(messages, options: options)
    }

    /// Streaming variant of the agent loop. Yields text deltas live as the model
    /// produces them, brackets each tool execution with `.toolStarted`/`.toolFinished`,
    /// and finishes when the model returns plain text (no tool calls) or `maxRounds`
    /// is exhausted (in which case it appends a final non-streaming summary turn).
    static func streamWithTools(
        messages initialMessages: [AIMessage],
        provider: AIAgentProvider,
        tools: [AITool],
        options: AICompletionOptions = AICompletionOptions()
    ) -> AsyncThrowingStream<AIAgentEvent, Error> {
        // Tools carry `[String: Any]` schemas (not Sendable) but are immutable values
        // that only this one detached loop uses, so they cross as one unchecked box.
        let toolBox = UncheckedSendable(tools)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                let tools = toolBox.value
                var messages = initialMessages
                let maxRounds = 8
                var round = 0
                do {
                    while round < maxRounds {
                        if Task.isCancelled { continuation.finish(); return }
                        round += 1
                        // HTTP owns request retries; never replay a streaming round here.
                        let collectedCalls = try await streamOneRound(
                            messages: messages, provider: provider, tools: tools,
                            options: options, continuation: continuation)
                        if collectedCalls.isEmpty {
                            continuation.finish(); return
                        }
                        messages.append(AIMessage(role: .assistant,
                                                  content: AIToolCallsSentinel.encode(collectedCalls)))
                        for call in collectedCalls {
                            continuation.yield(.toolCall(call))
                            continuation.yield(.toolStarted(call.toolName))
                            let result: String
                            if let tool = tools.first(where: { $0.name == call.toolName }) {
                                do { result = try await tool.execute(args: call.arguments) }
                                catch {
                                    // Log so operators can diagnose silently-failing tools;
                                    // the model still receives the error string so it can report back.
                                    ClippyLog.error("Tool \"\(call.toolName)\" failed: \(error)", category: ClippyLog.ai)
                                    result = "Tool error: \(error.localizedDescription)"
                                }
                            } else {
                                result = "Error: unknown tool \"\(call.toolName)\"."
                            }
                            messages.append(AIMessage(role: .user,
                                content: AIToolResultSentinel.encode(id: call.id, toolName: call.toolName, result: result)))
                            continuation.yield(.toolResult(id: call.id, name: call.toolName, result: result))
                            continuation.yield(.toolFinished(call.toolName))
                        }
                    }
                    // Round cap: one final non-streaming summary turn. Surface a
                    // "Summarising" toolActivity so the UI shows progress while the
                    // non-streaming call is in flight (audit [MEDIUM]).
                    continuation.yield(.toolStarted("Summarising"))
                    messages.append(AIMessage(role: .user, content: "Summarise what you accomplished for the user."))
                    let summary = try await provider.complete(messages, options: options)
                    continuation.yield(.toolFinished("Summarising"))
                    continuation.yield(.textDelta(summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Consume one provider stream and return its tool calls. HTTP owns retries.
    private static func streamOneRound(
        messages: [AIMessage],
        provider: AIAgentProvider,
        tools: [AITool],
        options: AICompletionOptions,
        continuation: AsyncThrowingStream<AIAgentEvent, Error>.Continuation
    ) async throws -> [AIToolCall] {
        var collectedCalls: [AIToolCall] = []
        for try await event in provider.streamWithTools(messages, tools: tools, options: options) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let text):
                continuation.yield(.textDelta(text))
            case .textReplace(let old, let new):
                continuation.yield(.textReplace(old: old, new: new))
            case .thinkingDelta:
                continue
            case .notice(let message):
                continuation.yield(.notice(message))
            case .usage(let reported):
                continuation.yield(.usage(reported))
            case .toolCalls(let calls):
                collectedCalls = calls
            case .done:
                break
            }
        }
        try Task.checkCancellation()
        return collectedCalls
    }
}
