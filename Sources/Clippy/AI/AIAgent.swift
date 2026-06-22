import Foundation

// MARK: - Agent-capable provider protocol

/// A provider that supports tool/function calling. Extends the base `AIProvider`
/// with a single agentic call: given messages and tools, return either a final
/// text answer or a list of tool calls the model wants to make.
///
/// API docs consulted:
///   OpenAI  — https://platform.openai.com/docs/guides/function-calling (2025-05 version)
///   Anthropic — https://docs.anthropic.com/en/docs/tool-use (2024-11 / anthropic-version 2023-06-01)
///   Ollama  — https://ollama.com/blog/tool-support (/api/chat, July 2024)
///   Azure   — OpenAI-compatible chat completions (api-version 2024-10-21)
protocol AIAgentProvider: AIProvider {
    /// One agentic turn. Returns `.text` when the model has a final answer, or
    /// `.toolCalls` with the list of calls the model wants to make.
    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn

    /// Streaming variant: yields text deltas live, then any tool calls, then `.done`.
    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error>
}

// MARK: - Turn result

enum AIAgentTurn {
    case text(String)
    case toolCalls([AIToolCall])
}

struct AIToolCall: Equatable {
    /// Provider-assigned call id (used by OpenAI/Azure/Anthropic to correlate
    /// the tool_result back to the tool_use block).
    let id: String
    let toolName: String
    /// JSON-decoded argument dictionary.
    let arguments: [String: Any]

    static func == (lhs: AIToolCall, rhs: AIToolCall) -> Bool {
        lhs.id == rhs.id && lhs.toolName == rhs.toolName
    }
}

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
                                            content: encodeToolCallsForHistory(calls))
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
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var messages = initialMessages
                let maxRounds = 8
                var round = 0
                do {
                    while round < maxRounds {
                        if Task.isCancelled { continuation.finish(); return }
                        round += 1
                        // Consume one streaming round, retrying transient errors
                        // (audit [MEDIUM]). Surfaced "Retrying..." as a toolActivity
                        // so the user sees the retry instead of a silent spinner.
                        let collectedCalls = try await streamOneRound(
                            messages: messages, provider: provider, tools: tools,
                            options: options, continuation: continuation)
                        if collectedCalls.isEmpty {
                            continuation.finish(); return
                        }
                        messages.append(AIMessage(role: .assistant,
                                                  content: encodeToolCallsForHistory(collectedCalls)))
                        for call in collectedCalls {
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

    /// Drive one streaming round with transient-error retry. Only retries while
    /// no text has been emitted for this round (a mid-stream retry would double
    /// the transcript). Returns the tool calls the round produced.
    private static func streamOneRound(
        messages: [AIMessage],
        provider: AIAgentProvider,
        tools: [AITool],
        options: AICompletionOptions,
        continuation: AsyncThrowingStream<AIAgentEvent, Error>.Continuation
    ) async throws -> [AIToolCall] {
        var attempt = 0
        while true {
            var collectedCalls: [AIToolCall] = []
            var yieldedText = false
            do {
                for try await event in provider.streamWithTools(messages, tools: tools, options: options) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let t):
                        yieldedText = true
                        continuation.yield(.textDelta(t))
                    case .toolCalls(let calls):
                        collectedCalls = calls
                    case .done:
                        break
                    }
                }
                return collectedCalls
            } catch {
                attempt += 1
                let canRetry = attempt < AIRetry.maxAttempts
                    && !yieldedText
                    && AIRetry.isTransient(error)
                guard canRetry else { throw error }
                // Surface the retry as a toolActivity so the bubble shows live
                // progress instead of stalling on a failed attempt.
                let label = "Retrying (attempt \(attempt + 1)/\(AIRetry.maxAttempts))..."
                continuation.yield(.toolStarted(label))
                try? await Task.sleep(for: .milliseconds(AIRetry.backoffMs(attempt)))
                if Task.isCancelled { throw CancellationError() }
                continuation.yield(.toolFinished(label))
            }
        }
    }

    // MARK: - Internal helpers

    /// Encode tool calls as a JSON string stored in the assistant message content
    /// field so the history stays serialisable in AIMessage (which holds a String).
    private static func encodeToolCallsForHistory(_ calls: [AIToolCall]) -> String {
        let payload = calls.map { c -> [String: Any] in
            [
                "id": c.id,
                "tool": c.toolName,
                "args": c.arguments,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "[tool calls]" }
        return s
    }
}

// MARK: - Tool-result sentinel

/// A tiny encoding that lets AIMessage (String content) carry a tool result
/// without adding a new `role` case. Concrete providers decode this and emit
/// the correct wire-format message (tool / tool_result / etc.).
enum AIToolResultSentinel {
    static let prefix = "__tool_result__:"

    static func encode(id: String, toolName: String, result: String) -> String {
        let payload: [String: Any] = ["id": id, "tool": toolName, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return result }
        return "\(prefix)\(s)"
    }

    /// Returns (id, toolName, result) if `content` was encoded by `encode`.
    static func decode(_ content: String) -> (id: String, toolName: String, result: String)? {
        guard content.hasPrefix(prefix) else { return nil }
        let json = String(content.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let toolName = obj["tool"] as? String,
              let result = obj["result"] as? String else { return nil }
        return (id, toolName, result)
    }
}

// MARK: - OpenAI agent provider
//
// Wire format (OpenAI Chat Completions API, 2025-05):
//   Request  — tools: [{ type, function: { name, description, parameters } }]
//   Response — choices[0].message.tool_calls?: [{ id, type, function: { name, arguments } }]
//              choices[0].finish_reason == "tool_calls" when calling
//   Tool result message — { role: "tool", tool_call_id: id, content: result }

struct OpenAIAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    // Pass-through for the non-tool path.
    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/chat/completions",
            headers: ["Authorization": "Bearer \(config.apiKey)"],
            body: [
                "model": config.model,
                "messages": AIHTTP.messagePayload(messages),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let body: [String: Any] = [
            "model": config.model,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
        ]
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/chat/completions",
            headers: ["Authorization": "Bearer \(config.apiKey)"],
            body: body
        )
        return try Self.parseTurn(data)
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let body: [String: Any] = [
            "model": config.model,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "stream": true,
        ]
        let lines = AIStreamingHTTP.postLines(
            url: "\(config.baseURL)/v1/chat/completions",
            headers: ["Authorization": "Bearer \(config.apiKey)"],
            body: body)
        return Self.eventStream(from: lines, accumulator: OpenAIStreamAccumulator())
    }

    /// Shared driver: feed lines through an OpenAI accumulator, emit text deltas
    /// live, then emit tool calls (if any) and `.done` at end. Reused by Azure.
    static func eventStream(from lines: AsyncThrowingStream<String, Error>,
                            accumulator: OpenAIStreamAccumulator)
        -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var acc = accumulator
                do {
                    for try await line in lines {
                        if let text = acc.consume(line: line) { continuation.yield(.textDelta(text)) }
                    }
                    let calls = acc.finishToolCalls()
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Wire helpers

    static func wireMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.map { msg in
            if let (id, _, result) = AIToolResultSentinel.decode(msg.content) {
                // tool result — OpenAI wants role:"tool" with tool_call_id
                return ["role": "tool", "tool_call_id": id, "content": result]
            }
            return ["role": msg.role.rawValue, "content": msg.content]
        }
    }

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIError.decoding("OpenAI: missing choices[0].message")
        }
        let finishReason = first["finish_reason"] as? String ?? ""
        if finishReason == "tool_calls",
           let toolCalls = message["tool_calls"] as? [[String: Any]] {
            let calls = toolCalls.compactMap { tc -> AIToolCall? in
                guard let id = tc["id"] as? String,
                      let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let argsString = fn["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else { return nil }
                return AIToolCall(id: id, toolName: name, arguments: args)
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw AIError.empty
        }
        return .text(content)
    }
}

// MARK: - Anthropic agent provider
//
// Wire format (Anthropic Messages API, anthropic-version: 2023-06-01):
//   Request  — tools: [{ name, description, input_schema }]
//   Response — stop_reason == "tool_use"; content: [{ type:"tool_use", id, name, input }]
//              Final text: content: [{ type:"text", text }]
//   Tool result — role:"user", content:[{ type:"tool_result", tool_use_id: id, content: result }]

struct AnthropicAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": AIHTTP.messagePayload(turns),
        ]
        if !system.isEmpty { body["system"] = system }
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/messages",
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
        return try AIHTTP.string(data, at: ["content", 0, "text"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.anthropicToolSpec),
        ]
        if !system.isEmpty { body["system"] = system }
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/v1/messages",
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
        return try Self.parseTurn(data)
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.anthropicToolSpec),
            "stream": true,
        ]
        if !system.isEmpty { body["system"] = system }
        let lines = AIStreamingHTTP.postLines(
            url: "\(config.baseURL)/v1/messages",
            headers: ["x-api-key": config.apiKey, "anthropic-version": "2023-06-01"],
            body: body)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var acc = AnthropicStreamAccumulator()
                do {
                    for try await line in lines {
                        if let text = acc.consume(line: line) { continuation.yield(.textDelta(text)) }
                    }
                    let calls = acc.finishToolCalls()
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Wire helpers

    static func wireMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        // Group consecutive tool results under a single user turn — Anthropic
        // requires tool_result blocks in a user message's content array.
        var result: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            result.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }

        for msg in messages {
            if msg.role == .system { continue }
            if let (id, _, toolResult) = AIToolResultSentinel.decode(msg.content) {
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": toolResult,
                ])
            } else {
                flushToolResults()
                result.append(["role": msg.role.rawValue, "content": msg.content])
            }
        }
        flushToolResults()
        return result
    }

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw AIError.decoding("Anthropic: missing content array")
        }
        let stopReason = root["stop_reason"] as? String ?? ""
        if stopReason == "tool_use" {
            let calls = content.compactMap { block -> AIToolCall? in
                guard let type_ = block["type"] as? String, type_ == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any] else { return nil }
                return AIToolCall(id: id, toolName: name, arguments: input)
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        // Gather text blocks.
        let text = content.compactMap { block -> String? in
            guard let type_ = block["type"] as? String, type_ == "text",
                  let t = block["text"] as? String else { return nil }
            return t
        }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return .text(text)
    }
}

// MARK: - Ollama agent provider
//
// Wire format (Ollama /api/chat, July 2024):
//   Request  — tools: [{ type, function: { name, description, parameters } }]
//              (same shape as OpenAI)
//   Response — message.tool_calls?: [{ function: { name, arguments } }]
//              (no id field — we generate a synthetic one)
//   Tool result — role:"tool", content: result string

struct OllamaAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/api/chat",
            headers: [:],
            body: [
                "model": config.model,
                "messages": AIHTTP.messagePayload(messages),
                "stream": false,
                "options": ["temperature": options.temperature],
            ]
        )
        return try AIHTTP.string(data, at: ["message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let data = try await AIHTTP.post(
            url: "\(config.baseURL)/api/chat",
            headers: [:],
            body: [
                "model": config.model,
                "messages": Self.wireMessages(messages),
                "tools": tools.map(\.openAIFunctionSpec),
                "stream": false,
                "options": ["temperature": options.temperature],
            ]
        )
        return try Self.parseTurn(data)
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let body: [String: Any] = [
            "model": config.model,
            "messages": Self.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "stream": true,
            "options": ["temperature": options.temperature],
        ]
        let lines = AIStreamingHTTP.postLines(url: "\(config.baseURL)/api/chat", headers: [:], body: body)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var acc = OllamaStreamAccumulator()
                do {
                    for try await line in lines {
                        if let text = acc.consume(line: line) { continuation.yield(.textDelta(text)) }
                    }
                    let calls = acc.finishToolCalls()
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func wireMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.map { msg in
            if let (_, _, result) = AIToolResultSentinel.decode(msg.content) {
                return ["role": "tool", "content": result]
            }
            return ["role": msg.role.rawValue, "content": msg.content]
        }
    }

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else {
            throw AIError.decoding("Ollama: missing message")
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            var idx = 0
            let calls = toolCalls.compactMap { tc -> AIToolCall? in
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                // Ollama may return arguments as a dict or as a JSON string.
                let args: [String: Any]
                if let d = fn["arguments"] as? [String: Any] {
                    args = d
                } else if let s = fn["arguments"] as? String,
                          let data = s.data(using: .utf8),
                          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    args = d
                } else {
                    args = [:]
                }
                idx += 1
                return AIToolCall(id: "ollama-\(idx)", toolName: name, arguments: args)
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw AIError.empty
        }
        return .text(content)
    }
}

// MARK: - Azure AI Foundry agent provider
//
// Wire format: OpenAI-compatible chat completions.
// API version: 2024-10-21 (set in AIProviderConfig.apiVersion).

struct AzureFoundryAgentProvider: AIAgentProvider {
    let config: AIProviderConfig

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let data = try await AIHTTP.post(
            url: url, headers: ["api-key": config.apiKey],
            body: [
                // Use the same wire transform as the agentic path so that
                // tool-result sentinel messages (injected by AIAgent.streamWithTools
                // at the round-cap summary turn) are correctly shaped for Azure.
                "messages": OpenAIAgentProvider.wireMessages(messages),
                "temperature": options.temperature,
                "max_tokens": options.maxTokens,
            ]
        )
        return try AIHTTP.string(data, at: ["choices", 0, "message", "content"])
    }

    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let body: [String: Any] = [
            "messages": OpenAIAgentProvider.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
        ]
        let data = try await AIHTTP.post(url: url, headers: ["api-key": config.apiKey], body: body)
        // Azure returns the same shape as OpenAI.
        return try OpenAIAgentProvider.parseTurn(data)
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let url = "\(config.baseURL)/openai/deployments/\(config.model)/chat/completions?api-version=\(config.apiVersion)"
        let body: [String: Any] = [
            "messages": OpenAIAgentProvider.wireMessages(messages),
            "tools": tools.map(\.openAIFunctionSpec),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "stream": true,
        ]
        let lines = AIStreamingHTTP.postLines(url: url, headers: ["api-key": config.apiKey], body: body)
        return OpenAIAgentProvider.eventStream(from: lines, accumulator: OpenAIStreamAccumulator())
    }
}

// MARK: - Agent provider factory

enum AIAgentProviderFactory {
    static func make(kind: AIProviderKind, config: AIProviderConfig) -> AIAgentProvider {
        switch kind {
        case .openai:       return OpenAIAgentProvider(config: config)
        case .anthropic:    return AnthropicAgentProvider(config: config)
        case .ollama:       return OllamaAgentProvider(config: config)
        case .azureFoundry: return AzureFoundryAgentProvider(config: config)
        }
    }
}

// MARK: - Streaming accumulators
//
// Pure, stateful parsers that turn raw stream lines into text deltas + tool
// calls. They have no networking; feed raw lines and read results at the end.
//
// Architecture:
//   StreamParser          - top-level protocol (consume + finishToolCalls)
//   SSEStreamParser       - refines StreamParser; shared SSE framing default
//                           for consume(line:); conformers supply decodeSSEPayload
//   OpenAIStreamAccumulator  : SSEStreamParser  (OpenAI/Azure wire format)
//   AnthropicStreamAccumulator : SSEStreamParser (Anthropic event format)
//   OllamaStreamAccumulator  : StreamParser     (plain JSONL, not SSE)
//
// OpenAI and Anthropic share the SSE line-framing loop (data: prefix, DONE
// sentinel, JSON root extraction) via the SSEStreamParser extension.
// Their payload decode, storage shapes, and finishToolCalls() all differ and
// stay per-conformer. Ollama is plain JSONL so it opts out of SSEStreamParser
// entirely and provides its own consume(line:).

// MARK: - StreamParser protocol

/// A streaming accumulator: feed raw lines one at a time; get back any text
/// delta immediately; read assembled tool calls at end-of-stream.
protocol StreamParser {
    /// Process one raw line. Returns the text delta to emit, or nil.
    mutating func consume(line: String) -> String?
    /// Called once after the last line. Returns any accumulated tool calls.
    func finishToolCalls() -> [AIToolCall]
}

// MARK: - SSEStreamParser (shared SSE line framing)

/// Refines StreamParser for providers that use SSE (`data: <json>` lines).
/// The default consume(line:) handles the framing: checks the `data:` prefix,
/// strips it, skips the `[DONE]` sentinel, parses the JSON root, and calls
/// decodeSSEPayload(root:) so each conformer only supplies the decode step.
protocol SSEStreamParser: StreamParser {
    /// Decode one already-parsed SSE JSON payload. Returns any text delta.
    /// Mutating because conformers accumulate tool fragments here.
    mutating func decodeSSEPayload(root: [String: Any]) -> String?
}

extension SSEStreamParser {
    /// Shared SSE framing: strips `data:` prefix, skips `[DONE]`, parses JSON,
    /// delegates the payload decode to the conformer.
    mutating func consume(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decodeSSEPayload(root: root)
    }
}

// MARK: - OpenAI / Azure accumulator

/// Accumulates OpenAI/Azure chat-completions SSE deltas into events.
/// Pure: feed each raw SSE line; text is returned immediately, tool calls are
/// assembled from fragments and read out at the end via `finishToolCalls()`.
struct OpenAIStreamAccumulator: SSEStreamParser {
    private var toolFragments: [Int: (id: String, name: String, args: String)] = [:]
    private var sawToolCalls = false

    // SSEStreamParser: only the OpenAI-specific payload decode lives here.
    // Wire shape: choices[0].delta.tool_calls[*] with function.arguments
    // accumulated as a JSON string keyed by index.
    mutating func decodeSSEPayload(root: [String: Any]) -> String? {
        guard let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            sawToolCalls = true
            for tc in calls {
                let idx = tc["index"] as? Int ?? 0
                var entry = toolFragments[idx] ?? (id: "", name: "", args: "")
                if let id = tc["id"] as? String { entry.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let n = fn["name"] as? String { entry.name = n }
                    if let a = fn["arguments"] as? String { entry.args += a }
                }
                toolFragments[idx] = entry
            }
        }
        if let content = delta["content"] as? String, !content.isEmpty { return content }
        return nil
    }

    func finishToolCalls() -> [AIToolCall] {
        guard sawToolCalls else { return [] }
        return toolFragments.sorted { $0.key < $1.key }.compactMap { _, frag in
            guard !frag.name.isEmpty else { return nil }
            let args = (frag.args.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            return AIToolCall(id: frag.id.isEmpty ? "openai-\(frag.name)" : frag.id,
                              toolName: frag.name, arguments: args)
        }
    }
}

// MARK: - Anthropic accumulator

/// Accumulates Anthropic Messages SSE events into text deltas + tool calls.
/// Uses a different event schema (content_block_start/delta, partial_json)
/// from the OpenAI wire format, so it supplies its own decodeSSEPayload while
/// still sharing the SSE line-framing loop via SSEStreamParser.
struct AnthropicStreamAccumulator: SSEStreamParser {
    private var blocks: [Int: (type: String, id: String, name: String, json: String)] = [:]
    private var stopReason = ""

    // SSEStreamParser: Anthropic-specific event dispatch.
    // Wire shape: content_block_start carries id+name; content_block_delta
    // carries text_delta for text or input_json_delta (partial_json) for tools.
    mutating func decodeSSEPayload(root: [String: Any]) -> String? {
        guard let type = root["type"] as? String else { return nil }
        switch type {
        case "content_block_start":
            let idx = root["index"] as? Int ?? 0
            if let block = root["content_block"] as? [String: Any] {
                let t = block["type"] as? String ?? ""
                blocks[idx] = (type: t, id: block["id"] as? String ?? "",
                               name: block["name"] as? String ?? "", json: "")
            }
        case "content_block_delta":
            let idx = root["index"] as? Int ?? 0
            if let delta = root["delta"] as? [String: Any] {
                if let t = delta["text"] as? String, (delta["type"] as? String) == "text_delta" {
                    return t
                }
                if let pj = delta["partial_json"] as? String,
                   (delta["type"] as? String) == "input_json_delta" {
                    blocks[idx]?.json += pj
                }
            }
        case "message_delta":
            if let d = root["delta"] as? [String: Any], let sr = d["stop_reason"] as? String {
                stopReason = sr
            }
        default:
            break
        }
        return nil
    }

    func finishToolCalls() -> [AIToolCall] {
        guard stopReason == "tool_use" else { return [] }
        return blocks.sorted { $0.key < $1.key }.compactMap { _, b in
            guard b.type == "tool_use" else { return nil }
            let args = (b.json.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            return AIToolCall(id: b.id, toolName: b.name, arguments: args)
        }
    }
}

// MARK: - Ollama accumulator

/// Accumulates Ollama /api/chat JSONL lines into text deltas + tool calls.
/// Ollama uses plain JSONL (one JSON object per line, no `data:` prefix), so
/// it conforms directly to StreamParser and skips the SSE framing path.
struct OllamaStreamAccumulator: StreamParser {
    private var pendingToolCalls: [AIToolCall] = []

    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            var idx = 0
            pendingToolCalls = calls.compactMap { tc in
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                let args: [String: Any]
                if let d = fn["arguments"] as? [String: Any] { args = d }
                else if let s = fn["arguments"] as? String,
                        let dd = s.data(using: .utf8),
                        let d = try? JSONSerialization.jsonObject(with: dd) as? [String: Any] { args = d }
                else { args = [:] }
                idx += 1
                return AIToolCall(id: "ollama-\(idx)", toolName: name, arguments: args)
            }
        }
        if let content = message["content"] as? String, !content.isEmpty { return content }
        return nil
    }

    func finishToolCalls() -> [AIToolCall] { pendingToolCalls }
}
