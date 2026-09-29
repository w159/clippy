import Foundation

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
                "messages": AIHTTP.messagePayload(AIMessageBuilder.plainText(messages)),
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
            "messages": AIMessageBuilder.openAI(messages),
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
        var body: [String: Any] = [
            "model": config.model,
            "messages": AIMessageBuilder.openAI(messages),
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty { body["tools"] = tools.map(\.openAIFunctionSpec) }
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
                    if let usage = acc.usage { continuation.yield(.usage(usage)) }
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
            let calls = toolCalls.compactMap { toolCall -> AIToolCall? in
                guard let id = toolCall["id"] as? String,
                      let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let argsString = function["arguments"] as? String,
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
