import Foundation

enum AIResponseParser {
    static func parseTurn(_ data: Data, family: WireFamily) throws -> AIAgentTurn {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.decoding("Expected response object") }
        if root["error"] != nil { throw AIError.decoding(AIErrorMapper.message(data)) }
        var text = ""
        var calls: [AIToolCall] = []
        var limited = false
        switch family {
        case .openaiChat, .azureV1, .azureDeployments:
            guard let choice = (root["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any] else { throw AIError.decoding("Missing choices[0].message") }
            text = message["content"] as? String ?? ""
            calls = try toolCalls(message["tool_calls"])
            limited = choice["finish_reason"] as? String == "length"
        case .ollamaChat:
            guard let message = root["message"] as? [String: Any] else { throw AIError.decoding("Missing message") }
            text = message["content"] as? String ?? ""
            calls = try toolCalls(message["tool_calls"])
            limited = root["done_reason"] as? String == "length"
        case .anthropicMessages:
            guard let blocks = root["content"] as? [[String: Any]] else { throw AIError.decoding("Missing content blocks") }
            for block in blocks {
                if block["type"] as? String == "text" { text += block["text"] as? String ?? "" }
                if block["type"] as? String == "tool_use", let name = block["name"] as? String,
                   let args = block["input"] as? [String: Any] {
                    calls.append(AIToolCall(id: block["id"] as? String ?? UUID().uuidString, toolName: name, arguments: args, replayBlocks: try JSONSerialization.data(withJSONObject: blocks)))
                }
            }
            limited = root["stop_reason"] as? String == "max_tokens"
        case .geminiNative:
            guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { throw AIError.decoding("Missing candidate; check Gemini safety feedback") }
            let content = candidate["content"] as? [String: Any]
            for part in content?["parts"] as? [[String: Any]] ?? [] where part["thought"] as? Bool != true { text += part["text"] as? String ?? "" }
            limited = candidate["finishReason"] as? String == "MAX_TOKENS"
        case .appleFoundation: throw AIError.decoding("Apple Intelligence has no wire response")
        }
        if !calls.isEmpty { return .toolCalls(calls) }
        guard !text.isEmpty else { throw limited ? AIError.outputLimitDuringReasoning : AIError.empty }
        return .text(text)
    }

    static func arguments(_ value: Any?) throws -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let string = value as? String, let dictionary = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] { return dictionary }
        throw AIError.decoding("Tool arguments must be a JSON object")
    }
    static func toolCalls(_ value: Any?) throws -> [AIToolCall] {
        guard let wire = value as? [[String: Any]] else { return [] }
        return try wire.enumerated().map { index, call in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { throw AIError.decoding("Malformed tool call") }
            return AIToolCall(id: call["id"] as? String ?? "call-\(index)", toolName: name, arguments: try arguments(function["arguments"]))
        }
    }
}

struct AIResponseStreamParser {
    let family: WireFamily
    private var openAI = OpenAIStreamAccumulator()
    private var anthropic = AnthropicStreamAccumulator()
    private var ollama = OllamaStreamAccumulator()
    private var sseData: [String] = []
    private var errorEvent = false
    private var visible = false
    private var limited = false
    private var replay: [Int: [String: Any]] = [:]
    private var toolJSON: [Int: String] = [:]

    init(family: WireFamily) { self.family = family }

    mutating func consume(line: String) throws -> [AIStreamEvent] {
        if family == .ollamaChat { return try payload(line) }
        if line.hasPrefix("event:") { errorEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces) == "error"; return [] }
        if line.hasPrefix("data:") {
            // Most providers emit one JSON object on one data line. Multi-line SSE waits for the blank separator.
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { return [] }
            if sseData.isEmpty, (try? JSONSerialization.jsonObject(with: Data(value.utf8))) != nil { return try payload(value) }
            sseData.append(value)
        }
        if line.isEmpty && !sseData.isEmpty {
            let value = sseData.joined(separator: "\n"); sseData = []
            return try payload(value)
        }
        return []
    }

    private mutating func payload(_ json: String) throws -> [AIStreamEvent] {
        guard !json.isEmpty else { return [] }
        let data = Data(json.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.decoding("Invalid stream JSON") }
        if errorEvent || root["error"] != nil || root["type"] as? String == "error" {
            errorEvent = false
            throw AIError.decoding(AIErrorMapper.message(data))
        }
        var events: [AIStreamEvent] = []
        var text: String?
        var thinking: String?
        switch family {
        case .openaiChat, .azureV1, .azureDeployments:
            text = openAI.decodeSSEPayload(root: root)
            let choice = (root["choices"] as? [[String: Any]])?.first
            let delta = choice?["delta"] as? [String: Any]
            thinking = delta?["reasoning_content"] as? String ?? delta?["reasoning"] as? String
            limited = limited || choice?["finish_reason"] as? String == "length"
        case .anthropicMessages:
            let index = root["index"] as? Int ?? 0
            if root["type"] as? String == "content_block_start", let block = root["content_block"] as? [String: Any] {
                replay[index] = block
            }
            if let delta = root["delta"] as? [String: Any] {
                for field in ["thinking", "signature", "text"] {
                    if let chunk = delta[field] as? String {
                        replay[index, default: [:]][field] = (replay[index]?[field] as? String ?? "") + chunk
                    }
                }
                if let chunk = delta["partial_json"] as? String { toolJSON[index, default: ""] += chunk }
            }
            text = anthropic.decodeSSEPayload(root: root)
            thinking = (root["delta"] as? [String: Any])?["thinking"] as? String
            limited = limited || (root["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens"
        case .ollamaChat:
            if let message = root["message"] as? [String: Any], message["tool_calls"] != nil {
                _ = try AIResponseParser.toolCalls(message["tool_calls"])
            }
            text = ollama.decodePayload(root: root)
            thinking = (root["message"] as? [String: Any])?["thinking"] as? String
            limited = limited || root["done_reason"] as? String == "length"
        case .geminiNative:
            let candidate = (root["candidates"] as? [[String: Any]])?.first
            let content = candidate?["content"] as? [String: Any]
            for part in content?["parts"] as? [[String: Any]] ?? [] {
                if let value = part["text"] as? String {
                    if part["thought"] as? Bool == true { events.append(.thinkingDelta(value)) }
                    else { events.append(.textDelta(value)); visible = true }
                }
            }
            if let usage = root["usageMetadata"] as? [String: Any] {
                events.append(.usage(AIUsage(promptTokens: usage["promptTokenCount"] as? Int ?? 0, completionTokens: usage["candidatesTokenCount"] as? Int ?? 0)))
            }
            limited = limited || candidate?["finishReason"] as? String == "MAX_TOKENS"
        case .appleFoundation: break
        }
        if let thinking, !thinking.isEmpty { events.append(.thinkingDelta(thinking)) }
        if let text, !text.isEmpty { visible = true; events.append(.textDelta(text)) }
        return events
    }

    mutating func finish() throws -> [AIStreamEvent] {
        var result: [AIStreamEvent] = []
        if !sseData.isEmpty { let json = sseData.joined(separator: "\n"); sseData = []; result += try payload(json) }
        if [.openaiChat, .azureV1, .azureDeployments].contains(family) { try openAI.validateToolArguments() }
        var calls: [AIToolCall]
        let usage: AIUsage?
        switch family {
        case .anthropicMessages: calls = anthropic.finishToolCalls(); usage = anthropic.usage
        case .ollamaChat: calls = ollama.finishToolCalls(); usage = ollama.usage
        default: calls = openAI.finishToolCalls(); usage = openAI.usage
        }
        if family == .anthropicMessages && !calls.isEmpty {
            for (index, json) in toolJSON { replay[index]?["input"] = try AIResponseParser.arguments(json) }
            let blocks = replay.sorted { $0.key < $1.key }.map(\.value)
            let data = try JSONSerialization.data(withJSONObject: blocks)
            for index in calls.indices { calls[index].replayBlocks = data }
        }
        if let usage { result.append(.usage(usage)) }
        if !calls.isEmpty { result.append(.toolCalls(calls)) }
        if !visible && calls.isEmpty {
            if limited { throw AIError.outputLimitDuringReasoning }
            throw AIError.empty
        }
        result.append(.done)
        return result
    }
}
