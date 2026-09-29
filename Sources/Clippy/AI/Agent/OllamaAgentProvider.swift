import Foundation

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
                "messages": AIHTTP.messagePayload(AIMessageBuilder.plainText(messages)),
                "stream": false,
                "options": OllamaOptions.payload(options),
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
                "messages": AIMessageBuilder.ollama(messages),
                "tools": tools.map(\.openAIFunctionSpec),
                "stream": false,
                "options": OllamaOptions.payload(options),
            ]
        )
        return try Self.parseTurn(data)
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        var body: [String: Any] = [
            "model": config.model,
            "messages": AIMessageBuilder.ollama(messages),
            "stream": true,
            "options": OllamaOptions.payload(options),
        ]
        if !tools.isEmpty { body["tools"] = tools.map(\.openAIFunctionSpec) }
        let lines = AIStreamingHTTP.postLines(url: "\(config.baseURL)/api/chat", headers: [:], body: body)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var acc = OllamaStreamAccumulator()
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

    static func parseTurn(_ data: Data) throws -> AIAgentTurn {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else {
            throw AIError.decoding("Ollama: missing message")
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            var idx = 0
            let calls = toolCalls.compactMap { toolCall -> AIToolCall? in
                guard let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }
                // Ollama may return arguments as a dict or as a JSON string.
                let args: [String: Any]
                if let argumentDict = function["arguments"] as? [String: Any] {
                    args = argumentDict
                } else if let argumentString = function["arguments"] as? String,
                          let data = argumentString.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    args = parsed
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
