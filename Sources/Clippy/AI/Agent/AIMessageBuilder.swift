import Foundation

// MARK: - Tool-result sentinel

/// A tiny encoding that lets AIMessage (String content) carry a tool result
/// without adding a new `role` case. Concrete providers decode this and emit
/// the correct wire-format message (tool / tool_result / etc.).
enum AIToolResultSentinel {
    static let prefix = "__tool_result__:"

    static func encode(id: String, toolName: String, result: String) -> String {
        let payload: [String: Any] = ["id": id, "tool": toolName, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return result }
        return "\(prefix)\(json)"
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

// MARK: - Tool-calls sentinel

/// Carries the assistant's tool-call turn through `AIMessage` (String content)
/// the same way `AIToolResultSentinel` carries results, so each provider can emit
/// its native tool-call shape instead of an assistant message full of JSON text.
enum AIToolCallsSentinel {
    static let prefix = "__tool_calls__:"

    static func encode(_ calls: [AIToolCall]) -> String {
        let payload = calls.map { call -> [String: Any] in
            var value: [String: Any] = ["id": call.id, "tool": call.toolName, "args": call.arguments]
            if let blocks = call.replayBlocks { value["replayBlocks"] = blocks.base64EncodedString() }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "[tool calls]" }
        return prefix + json
    }

    static func decode(_ content: String) -> [AIToolCall]? {
        guard content.hasPrefix(prefix),
              let data = String(content.dropFirst(prefix.count)).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.compactMap { entry in
            guard let id = entry["id"] as? String, let tool = entry["tool"] as? String else { return nil }
            return AIToolCall(id: id, toolName: tool, arguments: entry["args"] as? [String: Any] ?? [:],
                              replayBlocks: (entry["replayBlocks"] as? String).flatMap { Data(base64Encoded: $0) })
        }
    }

    static func jsonString(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - Shared wire-message builder

/// The one place tool-result sentinels become provider wire messages (AI-04).
/// Every provider, including the non-tool `complete` paths used by the round-cap
/// summary turn, routes through here so a raw `__tool_result__:` string can never
/// reach a model.
enum AIMessageBuilder {
    /// OpenAI / Azure chat-completions shape: tool results become `role: "tool"`.
    static func openAI(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.map { msg in
            if let calls = AIToolCallsSentinel.decode(msg.content) {
                let wire = calls.map { call -> [String: Any] in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.toolName,
                                  "arguments": AIToolCallsSentinel.jsonString(call.arguments)]]
                }
                return ["role": "assistant", "content": "", "tool_calls": wire]
            }
            if let decoded = AIToolResultSentinel.decode(msg.content) {
                return ["role": "tool", "tool_call_id": decoded.id, "content": decoded.result]
            }
            return ["role": msg.role.rawValue, "content": msg.content]
        }
    }

    /// Ollama shape: like OpenAI but Ollama has no tool_call_id.
    static func ollama(_ messages: [AIMessage]) -> [[String: Any]] {
        messages.map { msg in
            if let calls = AIToolCallsSentinel.decode(msg.content) {
                let wire = calls.map { call -> [String: Any] in
                    ["function": ["name": call.toolName, "arguments": call.arguments]]
                }
                return ["role": "assistant", "content": "", "tool_calls": wire]
            }
            if let decoded = AIToolResultSentinel.decode(msg.content) {
                return ["role": "tool", "content": decoded.result]
            }
            return ["role": msg.role.rawValue, "content": msg.content]
        }
    }

    /// Anthropic shape: system messages are dropped (callers send them in the
    /// top-level `system` field) and consecutive tool results are grouped under a
    /// single user turn of `tool_result` blocks.
    static func anthropic(_ messages: [AIMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var pending: [[String: Any]] = []
        func flush() {
            guard !pending.isEmpty else { return }
            result.append(["role": "user", "content": pending])
            pending = []
        }
        for msg in messages where msg.role != .system {
            if let calls = AIToolCallsSentinel.decode(msg.content) {
                flush()
                if let data = calls.first?.replayBlocks,
                   let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    result.append(["role": "assistant", "content": blocks])
                    continue
                }
                let blocks = calls.map { call -> [String: Any] in
                    ["type": "tool_use", "id": call.id, "name": call.toolName, "input": call.arguments]
                }
                result.append(["role": "assistant", "content": blocks])
            } else if let decoded = AIToolResultSentinel.decode(msg.content) {
                pending.append(["type": "tool_result", "tool_use_id": decoded.id, "content": decoded.result])
            } else {
                flush()
                result.append(["role": msg.role.rawValue, "content": msg.content])
            }
        }
        flush()
        return result
    }

    /// For calls that declare no tools (`complete`): a tool-result message has no
    /// matching tool call on the wire, so fold it into plain user text the model
    /// can read. Non-sentinel messages pass through unchanged.
    static func plainText(_ messages: [AIMessage]) -> [AIMessage] {
        messages.map { msg in
            if let calls = AIToolCallsSentinel.decode(msg.content) {
                let text = calls.map {
                    "Called tool \($0.toolName) with arguments \(AIToolCallsSentinel.jsonString($0.arguments))"
                }.joined(separator: "\n")
                return AIMessage(role: .assistant, content: text)
            }
            guard let decoded = AIToolResultSentinel.decode(msg.content) else { return msg }
            return AIMessage(role: .user,
                             content: "Result of tool \(decoded.toolName):\n\(decoded.result)")
        }
    }
}
