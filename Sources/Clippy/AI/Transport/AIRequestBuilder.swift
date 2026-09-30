import Foundation
import Synchronization

struct AIRequestQuirks: Sendable {
    var omitted: Set<String> = []
    var tokenField: String?
    var thinkLevel: String?
    var withoutTools = false
    var reasoningBudget = false
    /// Learned from a rejected/leaking `think` request: force thinking off or on for this model.
    var thinkOverride: ThinkOverride?
    /// From Ollama `/api/show`; nil = not probed or unknown (treated as not thinking).
    var thinkingCapable: Bool?

    enum ThinkOverride: Sendable, Equatable { case off, on }
}

enum AIQuirkCache {
    private static let storage = Mutex<[String: AIRequestQuirks]>([:])
    static func key(_ resolved: ResolvedProvider) -> String {
        resolved.instance.id.uuidString + ":" +
            ([WireFamily.azureDeployments, .azureV1].contains(resolved.descriptor.family) ? resolved.effectiveDeployment : resolved.effectiveModel)
    }
    static func get(_ resolved: ResolvedProvider) -> AIRequestQuirks {
        storage.withLock { $0[key(resolved)] ?? AIRequestQuirks() }
    }
    static func put(_ quirks: AIRequestQuirks, for resolved: ResolvedProvider) {
        storage.withLock { $0[key(resolved)] = quirks }
    }
    static func adjustment(message: String, current: AIRequestQuirks) -> AIRequestQuirks? {
        let lower = message.lowercased()
        var result = current
        if lower.contains("tools"), lower.contains("support") {
            result.withoutTools = true
        } else if lower.contains("max_tokens") {
            result.tokenField = "max_completion_tokens"
        } else if lower.contains("max_completion_tokens") {
            result.tokenField = "max_tokens"
        } else if let field = ["temperature", "stream_options", "think"].first(where: { lower.contains($0) }) {
            if field == "think", lower.contains("low") { result.thinkLevel = "low" }
            else { result.omitted.insert(field) }
        } else { return nil }
        return result
    }
}

struct AITimeouts: Sendable {
    let request: TimeInterval
    let firstToken: TimeInterval
    let idle: TimeInterval
    init(_ resolved: ResolvedProvider) {
        request = resolved.instance.requestTimeout > 0 ? resolved.instance.requestTimeout : 300
        firstToken = resolved.instance.firstTokenTimeout > 0 ? resolved.instance.firstTokenTimeout
            : ((resolved.descriptor.family == .ollamaChat || HostLocality.isVerifiedLoopback(resolved.effectiveBaseURL)) ? 300 : 60)
        idle = resolved.instance.idleTimeout > 0 ? resolved.instance.idleTimeout : 60
    }
    func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = request
        return configuration
    }
}

enum AIRequestBuilder {
    static func build(_ resolved: ResolvedProvider, messages: [AIMessage], tools: [AITool] = [],
                      options: AICompletionOptions, stream: Bool, quirks: AIRequestQuirks = AIRequestQuirks()) throws -> URLRequest {
        guard let url = resolved.url(for: stream ? .stream : .chat) else { throw AIError.badURL("Invalid provider endpoint or missing model/deployment") }
        let params = resolved.instance.params
        let cap = params.maxTokens ?? options.maxTokens
        let temperature = params.temperature ?? (resolved.descriptor.sendsTemperature ? options.temperature : nil)
        let family = resolved.descriptor.family
        let availableTools = resolved.descriptor.supportsTools && !quirks.withoutTools ? tools : []
        let turns = availableTools.isEmpty ? AIMessageBuilder.plainText(messages) : messages
        var body: [String: Any]
        switch family {
        case .openaiChat, .azureV1, .azureDeployments:
            body = openAI(resolved: resolved,
        messages: messages, turns: turns, tools: availableTools,
        cap: cap, temperature: temperature, stream: stream, quirks: quirks, purpose: options.purpose)
        case .anthropicMessages:
            body = anthropic(resolved: resolved,
        messages: messages, turns: turns, tools: availableTools,
        cap: cap, temperature: temperature, stream: stream, quirks: quirks, purpose: options.purpose)
        case .ollamaChat:
            body = ollama(resolved: resolved,
        messages: messages, turns: turns, tools: availableTools,
        cap: cap, temperature: temperature, stream: stream, quirks: quirks, purpose: options.purpose)
        case .geminiNative:
            body = gemini(resolved: resolved,
        messages: messages, turns: turns, tools: availableTools,
        cap: cap, temperature: temperature, stream: stream, quirks: quirks, purpose: options.purpose)
        case .appleFoundation: throw AIError.notConfigured("Apple Intelligence does not use HTTP")
        }
        body = try applyingExtra(body, json: resolved.instance.extraBodyJSON)
        body = applyingQuirks(body, quirks: quirks)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AITimeouts(resolved).request
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in resolved.allHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func applyingExtra(_ base: [String: Any], json: String) throws -> [String: Any] {
        var body = base
        let extra = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: Data(extra.utf8)) }
            catch { throw AIError.notConfigured("Advanced request body is invalid JSON: \(error.localizedDescription)") }
            guard let dictionary = object as? [String: Any] else { throw AIError.notConfigured("Advanced request body must be a JSON object, not an array or scalar.") }
            body = merge(body, dictionary)
        }
        return body
    }

    static func applyingQuirks(_ base: [String: Any], quirks: AIRequestQuirks) -> [String: Any] {
        var body = base
        // Learned server constraints apply even to overrides, otherwise every call repeats the same rejected request.
        for field in quirks.omitted {
            body.removeValue(forKey: field)
            if field == "temperature", var nested = body["options"] as? [String: Any] {
                nested.removeValue(forKey: field); body["options"] = nested
            }
        }
        if let tokenField = quirks.tokenField {
            let other = tokenField == "max_tokens" ? "max_completion_tokens" : "max_tokens"
            if let value = body.removeValue(forKey: other) { body[tokenField] = value }
        }
        if quirks.withoutTools { body.removeValue(forKey: "tools") }
        if let level = quirks.thinkLevel { body["think"] = level }
        switch quirks.thinkOverride {
        case .off?: body["think"] = false
        case .on?:
            body["think"] = true
            var options = body["options"] as? [String: Any] ?? [:]
            options["num_predict"] = max(options["num_predict"] as? Int ?? 0, 2048)
            body["options"] = options
        case nil: break
        }
        return body
    }

    private static func openAI(resolved: ResolvedProvider,
        messages: [AIMessage], turns: [AIMessage], tools: [AITool],
        cap: Int, temperature: Double?, stream: Bool, quirks: AIRequestQuirks, purpose: AICompletionPurpose) -> [String: Any] {
        let params = resolved.instance.params
        let family = resolved.descriptor.family
        var body: [String: Any]
            body = ["messages": AIMessageBuilder.openAI(turns), "stream": stream,
                    quirks.tokenField ?? resolved.descriptor.tokenLimitField: cap]
            if family != .azureDeployments { body["model"] = family == .azureV1 ? resolved.effectiveDeployment : resolved.effectiveModel }
            if let temperature { body["temperature"] = temperature }
            if let topP = params.topP { body["top_p"] = topP }
            if let effort = params.reasoningEffort { body["reasoning_effort"] = effort }
            if stream && resolved.descriptor.streamOptionsSupported { body["stream_options"] = ["include_usage": true] }
            if !tools.isEmpty { body["tools"] = tools.map(\.openAIFunctionSpec) }
        return body
    }

    private static func anthropic(resolved: ResolvedProvider,
        messages: [AIMessage], turns: [AIMessage], tools: [AITool],
        cap: Int, temperature: Double?, stream: Bool, quirks: AIRequestQuirks, purpose: AICompletionPurpose) -> [String: Any] {
        let params = resolved.instance.params
        var body: [String: Any]
            body = ["model": resolved.effectiveModel, "messages": AIMessageBuilder.anthropic(turns), "stream": stream, "max_tokens": cap]
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            if let temperature { body["temperature"] = temperature }
            if let topP = params.topP { body["top_p"] = topP }
            if let effort = params.reasoningEffort {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": effort]
            }
            if !tools.isEmpty { body["tools"] = tools.map(\.anthropicToolSpec) }
        return body
    }

    private static func ollama(resolved: ResolvedProvider,
        messages: [AIMessage], turns: [AIMessage], tools: [AITool],
        cap: Int, temperature: Double?, stream: Bool, quirks: AIRequestQuirks, purpose: AICompletionPurpose) -> [String: Any] {
        let params = resolved.instance.params
        var body: [String: Any]
            let capableQuick = purpose == .quick && quirks.thinkingCapable == true
                && params.thinkOllama == nil && params.reasoningEffort == nil
            var budget = quirks.reasoningBudget || quirks.thinkLevel != nil ? max(cap, 4096) : cap
            if capableQuick { budget = max(budget, 1024) }
            var ollamaOptions: [String: Any] = ["num_predict": budget]
            if let temperature { ollamaOptions["temperature"] = temperature }
            if let topP = params.topP { ollamaOptions["top_p"] = topP }
            body = ["model": resolved.effectiveModel, "messages": AIMessageBuilder.ollama(turns), "stream": stream, "options": ollamaOptions]
            if let level = quirks.thinkLevel ?? params.reasoningEffort { body["think"] = level }
            else if let think = params.thinkOllama { body["think"] = think }
            else if capableQuick { body["think"] = "low" }
            else if purpose == .quick { body["think"] = false }
            if !tools.isEmpty { body["tools"] = tools.map(\.openAIFunctionSpec) }
        return body
    }

    private static func gemini(resolved: ResolvedProvider,
        messages: [AIMessage], turns: [AIMessage], tools: [AITool],
        cap: Int, temperature: Double?, stream: Bool, quirks: AIRequestQuirks, purpose: AICompletionPurpose) -> [String: Any] {
        let params = resolved.instance.params
        var body: [String: Any]
            let contents = AIMessageBuilder.plainText(messages).filter { $0.role != .system }.map {
                ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] as [String: Any]
            }
            var generation: [String: Any] = ["maxOutputTokens": cap]
            if let temperature { generation["temperature"] = temperature }
            if let topP = params.topP { generation["topP"] = topP }
            if let effort = params.reasoningEffort { generation["thinkingConfig"] = ["thinkingLevel": effort] }
            body = ["contents": contents, "generationConfig": generation]
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        return body
    }

    static func merge(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in extra {
            if let old = result[key] as? [String: Any], let new = value as? [String: Any] { result[key] = merge(old, new) }
            else { result[key] = value }
        }
        return result
    }
}
