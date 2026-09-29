import Foundation

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
            "messages": AIHTTP.messagePayload(AIMessageBuilder.plainText(turns)),
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
            "messages": AIMessageBuilder.anthropic(messages),
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
            "messages": AIMessageBuilder.anthropic(messages),
            "stream": true,
        ]
        if !tools.isEmpty { body["tools"] = tools.map(\.anthropicToolSpec) }
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
                    if let usage = acc.usage { continuation.yield(.usage(usage)) }
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
        let joinedText = content.compactMap { block -> String? in
            guard let type_ = block["type"] as? String, type_ == "text",
                  let text = block["text"] as? String else { return nil }
            return text
        }.joined()
        guard !joinedText.isEmpty else { throw AIError.empty }
        return .text(joinedText)
    }
}
