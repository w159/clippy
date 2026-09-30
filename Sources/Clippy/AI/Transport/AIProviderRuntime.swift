import Foundation
import Synchronization

struct AIStreamActivity: Sendable {
    let start = ContinuousClock.now
    var last = ContinuousClock.now
    var receivedToken = false
    var timeout: String?
}

enum AITransportClient {
    static func retryDelay(status: Int, retryAfter: String?, attempt: Int) -> TimeInterval? {
        guard status == 429 || (500...599).contains(status) else { return nil }
        if let retryAfter {
            if let seconds = Double(retryAfter) { return max(0, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: retryAfter) { return max(0, date.timeIntervalSinceNow) }
        }
        return min(8, pow(2, Double(attempt)) * 0.5) + Double.random(in: 0...0.25)
    }

    static func lines(request: URLRequest, resolved: ResolvedProvider, deadline: ContinuousClock.Instant)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let timeouts = AITimeouts(resolved)
                let session = URLSession(configuration: timeouts.configuration())
                let activity = Mutex(AIStreamActivity())
                let watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        let phase = activity.withLock { state -> String? in
                            let now = ContinuousClock.now
                            if now >= deadline { state.timeout = "Overall request" }
                            else if !state.receivedToken && state.start.duration(to: now) > .seconds(timeouts.firstToken) { state.timeout = "First token" }
                            else if state.receivedToken && state.last.duration(to: now) > .seconds(timeouts.idle) { state.timeout = "Between chunks" }
                            return state.timeout
                        }
                        if phase != nil { session.invalidateAndCancel(); return }
                    }
                }
                defer { watchdog.cancel(); session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIError.decoding("No HTTP response") }
                    if !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count >= 65536 { break } }
                        throw AIHTTPResponseFailure(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        activity.withLock { state in
                            state.last = .now
                            // Header, blank and keepalive lines are not a first token.
                            if firstToken(in: line) { state.receivedToken = true }
                        }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    if let phase = activity.withLock({ $0.timeout }) { continuation.finish(throwing: AIErrorMapper.timeout(phase, resolved: resolved, purpose: .stream)) }
                    else if ContinuousClock.now >= deadline { continuation.finish(throwing: AIErrorMapper.timeout("Overall request", resolved: resolved, purpose: .stream)) }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func firstToken(in line: String) -> Bool {
        let json = line.hasPrefix("data:") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : line
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        func containsToken(_ object: Any) -> Bool {
            if let dictionary = object as? [String: Any] {
                for (key, value) in dictionary {
                    if ["text", "content", "thinking", "reasoning", "reasoning_content", "partial_json"].contains(key),
                       let text = value as? String, !text.isEmpty { return true }
                    if key == "tool_calls", let calls = value as? [Any], !calls.isEmpty { return true }
                    if containsToken(value) { return true }
                }
            }
            if let array = object as? [Any] { return array.contains(where: containsToken) }
            return false
        }
        return containsToken(root)
    }

    static func data(request: URLRequest, resolved: ResolvedProvider, deadline: ContinuousClock.Instant) async throws -> Data {
        let session = URLSession(configuration: AITimeouts(resolved).configuration())
        let watchdog = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { session.invalidateAndCancel() }
        }
        defer { watchdog.cancel(); session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIError.decoding("No HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw AIHTTPResponseFailure(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            return data
        } catch {
            if ContinuousClock.now >= deadline { throw AIErrorMapper.timeout("Overall request", resolved: resolved) }
            throw error
        }
    }
}

struct AIHTTPResponseFailure: Error, Sendable {
    let status: Int
    let body: Data
    let retryAfter: String?
}

enum AIProviderRuntime {
    static func make(_ resolved: ResolvedProvider) -> AIAgentProvider {
        if resolved.descriptor.family == .appleFoundation { return AppleIntelligenceProvider() }
        return AIResolvedHTTPProvider(resolved: resolved)
    }
}

struct AIResolvedHTTPProvider: AIAgentProvider {
    let resolved: ResolvedProvider

    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String {
        switch try await completeWithTools(messages, tools: [], options: options) {
        case .text(let text): return text
        case .toolCalls: throw AIError.decoding("Unexpected tool calls without declared tools")
        }
    }

    /// Cached quirks plus, for quick Ollama calls, the model's thinking capability.
    private func requestQuirks(_ options: AICompletionOptions) async -> AIRequestQuirks {
        var quirks = AIQuirkCache.get(resolved)
        if options.purpose == .chat { quirks.thinkOverride = nil; quirks.thinkingCapable = nil }
        if resolved.descriptor.family == .ollamaChat, options.purpose == .quick, quirks.thinkingCapable == nil {
            quirks.thinkingCapable = await AIOllamaCapabilities.isThinking(resolved)
        }
        return quirks
    }

    func completeWithTools(_ messages: [AIMessage], tools: [AITool], options: AICompletionOptions) async throws -> AIAgentTurn {
        var request = try AIRequestBuilder.build(resolved, messages: messages, tools: tools, options: options,
                                                 stream: false, quirks: await requestQuirks(options))
        var leakRetried = false
        var attempt = 0
        var adjusted = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(AITimeouts(resolved).request))
        while true {
            try Task.checkCancellation()
            do {
                let data = try await AITransportClient.data(request: request, resolved: resolved, deadline: deadline)
                let turn: AIAgentTurn
                do { turn = try AIResponseParser.parseTurn(data, family: resolved.descriptor.family) }
                catch let error as AIError where error == .empty || error == .outputLimitDuringReasoning {
                    if options.purpose == .quick, !leakRetried, let updated = try forceThinking(request) { leakRetried = true; request = updated; continue }
                    throw error
                }
                if case .text(let text) = turn, options.purpose == .quick, !leakRetried, AIReasoningLeak.looksLikeReasoning(text),
                   let updated = try forceThinking(request) { leakRetried = true; request = updated; continue }
                return turn
            } catch let failure as AIHTTPResponseFailure {
                if failure.status == 400 && !adjusted, let updated = try await adjust(request, failure: failure, deadline: deadline) {
                    request = updated; adjusted = true; continue
                }
                if attempt < 2, let delay = AITransportClient.retryDelay(status: failure.status, retryAfter: failure.retryAfter, attempt: attempt) {
                    attempt += 1; try await pause(delay, deadline: deadline); continue
                }
                throw AIError.provider(AIErrorMapper.failure(resolved: resolved, status: failure.status, data: failure.body))
            } catch {
                if (error as? URLError)?.code == .networkConnectionLost && attempt < 2 {
                    attempt += 1; try await pause(Double(attempt) + Double.random(in: 0...0.25), deadline: deadline); continue
                }
                throw AIErrorMapper.network(error: error, resolved: resolved)
            }
        }
    }

    func streamWithTools(_ messages: [AIMessage], tools: [AITool], options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        // Tools are not Sendable, so both variants are built here; the capability probe only picks one.
        var base = AIQuirkCache.get(resolved)
        if options.purpose == .chat { base.thinkOverride = nil; base.thinkingCapable = nil }
        var capable = base
        capable.thinkingCapable = true
        let plain = Result { try AIRequestBuilder.build(resolved, messages: messages, tools: tools, options: options, stream: true, quirks: base) }
        let thinking = Result { try AIRequestBuilder.build(resolved, messages: messages, tools: tools, options: options, stream: true, quirks: capable) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let probed = await requestQuirks(options).thinkingCapable == true
                    var request = try (probed ? thinking : plain).get()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(AITimeouts(resolved).request))
                    var attempt = 0
                    var adjusted = false
                    var leakRetried = false
                    while true {
                        var parser = AIResponseStreamParser(family: resolved.descriptor.family)
                        var emitted = false
                        var held: [AIStreamEvent] = []
                        let holdQuick = resolved.descriptor.family == .ollamaChat && options.purpose == .quick
                        do {
                            for try await line in AITransportClient.lines(request: request, resolved: resolved, deadline: deadline) {
                                for event in try parser.consume(line: line) {
                                    if holdQuick { held.append(event) }
                                    else { emitted = true; continuation.yield(event) }
                                }
                            }
                            let final = try parser.finish()
                            if holdQuick {
                                let answer = held.compactMap { event -> String? in
                                    if case .textDelta(let text) = event { return text }
                                    return nil
                                }.joined()
                                if !leakRetried && AIReasoningLeak.looksLikeReasoning(answer), let updated = try forceThinking(request) {
                                    leakRetried = true; request = updated; continue
                                }
                                for event in held { continuation.yield(event) }
                            }
                            for event in final { continuation.yield(event) }
                            continuation.finish(); return
                        } catch let error as AIError where (error == .empty || error == .outputLimitDuringReasoning) && !leakRetried && options.purpose == .quick {
                            guard let updated = try forceThinking(request) else { throw error }
                            leakRetried = true; request = updated
                        } catch let failure as AIHTTPResponseFailure {
                            if !emitted && failure.status == 400 && !adjusted, let updated = try await adjust(request, failure: failure, deadline: deadline) {
                                request = updated; adjusted = true
                                if AIQuirkCache.get(resolved).withoutTools { continuation.yield(.notice("This model does not support tools. Continuing without tools.")) }
                                continue
                            }
                            if !emitted && attempt < 2, let delay = AITransportClient.retryDelay(status: failure.status, retryAfter: failure.retryAfter, attempt: attempt) {
                                attempt += 1; try await pause(delay, deadline: deadline, purpose: .stream); continue
                            }
                            throw AIError.provider(AIErrorMapper.failure(resolved: resolved, status: failure.status, data: failure.body, purpose: .stream))
                        } catch {
                            if !emitted && (error as? URLError)?.code == .networkConnectionLost && attempt < 2 {
                                attempt += 1; try await pause(Double(attempt) + Double.random(in: 0...0.25), deadline: deadline, purpose: .stream); continue
                            }
                            throw AIErrorMapper.network(error: error, resolved: resolved, purpose: .stream)
                        }
                    }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pause(_ seconds: TimeInterval, deadline: ContinuousClock.Instant, purpose: EndpointPurpose = .chat) async throws {
        guard ContinuousClock.now.advanced(by: .seconds(seconds)) < deadline else { throw AIErrorMapper.timeout("Overall request", resolved: resolved, purpose: purpose) }
        try await Task.sleep(for: .seconds(seconds))
    }

    private func adjust(_ request: URLRequest, failure: AIHTTPResponseFailure, deadline: ContinuousClock.Instant) async throws -> URLRequest? {
        let message = AIErrorMapper.message(failure.body)
        guard var quirks = AIQuirkCache.adjustment(message: message, current: AIQuirkCache.get(resolved)),
              let data = request.httpBody, var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if resolved.descriptor.family == .ollamaChat && message.lowercased().contains("think") {
            quirks.reasoningBudget = true
            switch body["think"] {
            case is String:  // a named level was rejected: fall back to a plain off switch
                quirks.thinkLevel = nil; quirks.thinkOverride = .off
            case let flag as Bool where !flag:  // thinking-only model refuses off: use its own level, else on
                if let level = await supportedThinkingLevel(deadline: deadline) { quirks.thinkLevel = level; quirks.thinkOverride = nil }
                else { quirks.thinkOverride = .on }
            default:
                break
            }
            quirks.omitted.remove("think")
        }
        body = AIRequestBuilder.applyingQuirks(body, quirks: quirks)
        if quirks.withoutTools {
            body.removeValue(forKey: "tools")
            if var messages = body["messages"] as? [[String: Any]] {
                messages.removeAll { $0["role"] as? String == "tool" || $0["tool_calls"] != nil }
                body["messages"] = messages
            }
        }
        AIQuirkCache.put(quirks, for: resolved)
        var retry = request
        retry.httpBody = try JSONSerialization.data(withJSONObject: body)
        return retry
    }

    /// Last rung of the Ollama ladder: a quick request that sent `think` (false or a level) still produced
    /// nothing usable or leaked its reasoning, so retry once with thinking on and a larger budget.
    private func forceThinking(_ request: URLRequest) throws -> URLRequest? {
        guard resolved.descriptor.family == .ollamaChat,
              let data = request.httpBody, var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["think"] is String || (body["think"] as? Bool) == false else { return nil }
        var quirks = AIQuirkCache.get(resolved)
        quirks.thinkLevel = nil
        quirks.thinkOverride = .on
        AIQuirkCache.put(quirks, for: resolved)
        body = AIRequestBuilder.applyingQuirks(body, quirks: quirks)
        var retry = request
        retry.httpBody = try JSONSerialization.data(withJSONObject: body)
        return retry
    }

    private func supportedThinkingLevel(deadline: ContinuousClock.Instant) async -> String? {
        guard let base = resolved.effectiveBaseURL, let url = URLNormalizer.join(base: base, path: "/api/show") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": resolved.effectiveModel])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in resolved.allHeaders { request.setValue(value, forHTTPHeaderField: name) }
        guard let data = try? await AITransportClient.data(request: request, resolved: resolved, deadline: deadline),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thinking = root["thinking"] as? [String: Any] else { return nil }
        return (thinking["values"] as? [String])?.first ?? thinking["default"] as? String
    }
}

/// Ollama `/api/show` capability probe, cached for the process per provider+model.
enum AIOllamaCapabilities {
    private static let cache = Mutex<[String: Bool]>([:])

    static func isThinking(_ resolved: ResolvedProvider) async -> Bool {
        let key = AIQuirkCache.key(resolved)
        if let known = cache.withLock({ $0[key] }) { return known }
        guard let base = resolved.effectiveBaseURL, let url = URLNormalizer.join(base: base, path: "/api/show") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": resolved.effectiveModel])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in resolved.allHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard let data = try? await AITransportClient.data(request: request, resolved: resolved, deadline: deadline),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = root["capabilities"] as? [String] else { return false }  // unknown is not cached
        let thinking = capabilities.contains("thinking")
        cache.withLock { $0[key] = thinking }
        return thinking
    }
}

/// Models that ignore `think:false` print their chain of thought as the answer.
enum AIReasoningLeak {
    private static let openers = ["the user has ", "the user wants ", "the user is asking ", "user wants", "we need to", "we are asked", "let me ", "let's ", "okay, ", "ok, ",
                                  "i need to", "i should ", "first, ", "hmm", "alright, ", "the task ", "the request "]

    static func looksLikeReasoning(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return openers.contains { lower.hasPrefix($0) }
    }
}

struct AIConnectionResult: Sendable {
    var ok: Bool
    var summary: String
    var detail: String?
    var latency: TimeInterval?
    var requestURLDisplay: String
}

enum AIConnectionTester {
    static func test(_ resolved: ResolvedProvider) async -> AIConnectionResult {
        let start = ContinuousClock.now
        let url = resolved.descriptor.family == .appleFoundation ? "on device" : AIErrorMapper.displayURL(resolved.url(for: .chat))
        do {
            let text = try await AIProviderRuntime.make(resolved).complete([AIMessage(role: .user, content: "Reply only with OK.")],
                                                                          options: AICompletionOptions(maxTokens: 4096, purpose: .quick))
            let duration = start.duration(to: .now)
            let latency = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            return AIConnectionResult(ok: true, summary: "Connected successfully", detail: String(text.prefix(120)), latency: latency, requestURLDisplay: url)
        } catch {
            return AIConnectionResult(ok: false, summary: "Connection failed", detail: error.localizedDescription, latency: nil, requestURLDisplay: url)
        }
    }
}
