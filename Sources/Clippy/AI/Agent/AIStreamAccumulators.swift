import Foundation

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
    /// Token counts seen in the stream so far, or nil when the provider sent none.
    var usage: AIUsage? { get }
}

extension StreamParser {
    var usage: AIUsage? { nil }
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
    private(set) var usage: AIUsage?

    // SSEStreamParser: only the OpenAI-specific payload decode lives here.
    // Wire shape: choices[0].delta.tool_calls[*] with function.arguments
    // accumulated as a JSON string keyed by index.
    mutating func decodeSSEPayload(root: [String: Any]) -> String? {
        if let usageObject = root["usage"] as? [String: Any] {
            usage = AIUsage(promptTokens: usageObject["prompt_tokens"] as? Int ?? 0,
                            completionTokens: usageObject["completion_tokens"] as? Int ?? 0)
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            sawToolCalls = true
            for toolCall in calls {
                let idx = toolCall["index"] as? Int ?? 0
                var entry = toolFragments[idx] ?? (id: "", name: "", args: "")
                if let callID = toolCall["id"] as? String { entry.id = callID }
                if let function = toolCall["function"] as? [String: Any] {
                    if let toolName = function["name"] as? String { entry.name = toolName }
                    if let argumentChunk = function["arguments"] as? String { entry.args += argumentChunk }
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
    private(set) var usage: AIUsage?

    // SSEStreamParser: Anthropic-specific event dispatch.
    // Wire shape: content_block_start carries id+name; content_block_delta
    // carries text_delta for text or input_json_delta (partial_json) for tools.
    mutating func decodeSSEPayload(root: [String: Any]) -> String? {
        guard let type = root["type"] as? String else { return nil }
        switch type {
        case "message_start":
            if let msg = root["message"] as? [String: Any], let usageObject = msg["usage"] as? [String: Any] {
                usage = AIUsage(promptTokens: usageObject["input_tokens"] as? Int ?? 0,
                                completionTokens: usageObject["output_tokens"] as? Int ?? 0)
            }
        case "content_block_start":
            let idx = root["index"] as? Int ?? 0
            if let block = root["content_block"] as? [String: Any] {
                let blockType = block["type"] as? String ?? ""
                blocks[idx] = (type: blockType, id: block["id"] as? String ?? "",
                               name: block["name"] as? String ?? "", json: "")
            }
        case "content_block_delta":
            let idx = root["index"] as? Int ?? 0
            if let delta = root["delta"] as? [String: Any] {
                if let textChunk = delta["text"] as? String, (delta["type"] as? String) == "text_delta" {
                    return textChunk
                }
                if let partialJSON = delta["partial_json"] as? String,
                   (delta["type"] as? String) == "input_json_delta" {
                    blocks[idx]?.json += partialJSON
                }
            }
        case "message_delta":
            if let messageDelta = root["delta"] as? [String: Any], let reason = messageDelta["stop_reason"] as? String {
                stopReason = reason
            }
            if let usageObject = root["usage"] as? [String: Any], let out = usageObject["output_tokens"] as? Int {
                var current = usage ?? AIUsage()
                current.completionTokens = out
                usage = current
            }
        default:
            break
        }
        return nil
    }

    func finishToolCalls() -> [AIToolCall] {
        guard stopReason == "tool_use" else { return [] }
        return blocks.sorted { $0.key < $1.key }.compactMap { _, block in
            guard block.type == "tool_use" else { return nil }
            let args = (block.json.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            return AIToolCall(id: block.id, toolName: block.name, arguments: args)
        }
    }
}

// MARK: - Ollama accumulator

/// Accumulates Ollama /api/chat JSONL lines into text deltas + tool calls.
/// Ollama uses plain JSONL (one JSON object per line, no `data:` prefix), so
/// it conforms directly to StreamParser and skips the SSE framing path.
struct OllamaStreamAccumulator: StreamParser {
    private var pendingToolCalls: [AIToolCall] = []
    private(set) var usage: AIUsage?

    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }
        if root["done"] as? Bool == true {
            usage = AIUsage(promptTokens: root["prompt_eval_count"] as? Int ?? 0,
                            completionTokens: root["eval_count"] as? Int ?? 0)
        }
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            var idx = 0
            pendingToolCalls = calls.compactMap { toolCall in
                guard let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }
                let args: [String: Any]
                if let argumentDict = function["arguments"] as? [String: Any] { args = argumentDict }
                else if let argumentString = function["arguments"] as? String,
                        let argumentData = argumentString.data(using: .utf8),
                        let parsed = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] { args = parsed }
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
