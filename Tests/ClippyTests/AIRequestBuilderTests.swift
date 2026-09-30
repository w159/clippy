import Foundation
import XCTest
@testable import Clippy

@MainActor
final class AIRequestBuilderTests: XCTestCase {
    private let messages = [
        AIMessage(role: .system, content: "Be concise."),
        AIMessage(role: .user, content: "Hello"),
    ]

    private func resolved(_ id: String,
                          edit: (inout ProviderInstance) -> Void = { _ in }) throws -> ResolvedProvider {
        let descriptor = try XCTUnwrap(ProviderCatalog.descriptor(id: id))
        var instance = AIProviderStore.makeInstance(descriptor)
        instance.model = "fixture-model"
        edit(&instance)
        return ResolvedProvider(descriptor: descriptor, instance: instance,
                                apiKey: "fixture-secret", secretHeaders: ["X-Secret": "header-secret"])
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertBody(_ request: URLRequest, equals expected: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try body(request) as NSDictionary, expected as NSDictionary, file: file, line: line)
    }

    func testOpenAIRequestIncludesUsageButOmitsUnrequestedSampling() throws {
        let provider = try resolved("openai") {
            $0.organization = "org-fixture"
            $0.project = "project-fixture"
        }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(maxTokens: 77), stream: true)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Organization"), "org-fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Project"), "project-fixture")
        try assertBody(request, equals: [
            "model": "fixture-model", "stream": true, "max_completion_tokens": 77,
            "messages": [["role": "system", "content": "Be concise."], ["role": "user", "content": "Hello"]],
            "stream_options": ["include_usage": true],
        ])
    }

    func testExplicitSamplingAndInstanceCapOverrideActionDefaults() throws {
        let provider = try resolved("openai") {
            $0.params = GenerationParams(temperature: 0.3, maxTokens: 900, topP: 0.8, reasoningEffort: "low")
        }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(temperature: 0.9, maxTokens: 77), stream: false)
        let json = try body(request)
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 900)
        XCTAssertEqual(json["top_p"] as? Double, 0.8)
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        XCTAssertNil(json["stream_options"])
    }

    func testAnthropicSeparatesSystemAndUsesNativeCapAndAuth() throws {
        let provider = try resolved("anthropic")
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(temperature: 0.2, maxTokens: 77), stream: false)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        try assertBody(request, equals: [
            "model": "fixture-model", "stream": false, "max_tokens": 77, "temperature": 0.2,
            "system": "Be concise.", "messages": [["role": "user", "content": "Hello"]],
        ])
    }

    func testAnthropicReasoningMapsToAdaptiveThinkingAndOutputEffort() throws {
        let provider = try resolved("anthropic") { $0.params.reasoningEffort = "high" }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(maxTokens: 8192), stream: true)
        let json = try body(request)
        XCTAssertEqual(json["thinking"] as? [String: String], ["type": "adaptive"])
        XCTAssertEqual(json["output_config"] as? [String: String], ["effort": "high"])
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["stream_options"])
    }

    func testOllamaQuickRequestUsesNestedOptionsAndNoLocalAuth() throws {
        let provider = try resolved("ollama-local") { $0.params.topP = 0.8 }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(temperature: 0.2, maxTokens: 77, purpose: .quick),
                                                stream: true)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        try assertBody(request, equals: [
            "model": "fixture-model", "stream": true, "think": false,
            "messages": [["role": "system", "content": "Be concise."], ["role": "user", "content": "Hello"]],
            "options": ["num_predict": 77, "temperature": 0.2, "top_p": 0.8],
        ])
    }

    func testOllamaChatLeavesThinkingAutomaticAndExplicitChoiceWinsQuick() throws {
        let automatic = try AIRequestBuilder.build(resolved("ollama-cloud"), messages: messages,
                                                  options: AICompletionOptions(maxTokens: 77), stream: false)
        XCTAssertNil(try body(automatic)["think"])
        XCTAssertEqual(automatic.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        let explicit = try resolved("ollama-local") { $0.params.thinkOllama = true }
        let request = try AIRequestBuilder.build(explicit, messages: messages,
                                                options: AICompletionOptions(maxTokens: 77, purpose: .quick), stream: false)
        XCTAssertEqual(try body(request)["think"] as? Bool, true)
    }

    func testAzureDeploymentRequestEncodesAliasAndOmitsModelFromBody() throws {
        let provider = try resolved("azure-deployments") {
            $0.baseURL = "https://fixture.openai.azure.com/openai/v1/"
            $0.deployment = "deployed/a b"
            $0.apiVersion = "2025-01-01"
        }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(maxTokens: 77), stream: false)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://fixture.openai.azure.com/openai/deployments/deployed%2Fa%20b/chat/completions?api-version=2025-01-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "fixture-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        try assertBody(request, equals: [
            "stream": false, "max_completion_tokens": 77,
            "messages": [["role": "system", "content": "Be concise."], ["role": "user", "content": "Hello"]],
        ])
    }

    func testAzureV1UsesDeploymentAsModelWithoutAPIVersion() throws {
        let provider = try resolved("azure-v1") {
            $0.baseURL = "https://fixture.openai.azure.com/openai/v1"
            $0.deployment = "deployed-alias"
            $0.model = "unused-model"
        }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(maxTokens: 77), stream: false)
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.openai.azure.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "fixture-secret")
        try assertBody(request, equals: [
            "model": "deployed-alias", "stream": false, "max_completion_tokens": 77,
            "messages": [["role": "system", "content": "Be concise."], ["role": "user", "content": "Hello"]],
        ])
    }

    func testGeminiUsesNativeRolesGenerationAndDistinctStreamURL() throws {
        let provider = try resolved("gemini") { $0.params = GenerationParams(topP: 0.8, reasoningEffort: "low") }
        let turns = messages + [AIMessage(role: .assistant, content: "Hi")]
        let request = try AIRequestBuilder.build(provider, messages: turns,
                                                options: AICompletionOptions(temperature: 0.2, maxTokens: 77), stream: true)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/fixture-model:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        try assertBody(request, equals: [
            "contents": [["role": "user", "parts": [["text": "Hello"]]],
                         ["role": "model", "parts": [["text": "Hi"]]]],
            "systemInstruction": ["parts": [["text": "Be concise."]]],
            "generationConfig": ["maxOutputTokens": 77, "temperature": 0.2, "topP": 0.8,
                                 "thinkingConfig": ["thinkingLevel": "low"]],
        ])
        let chat = try AIRequestBuilder.build(provider, messages: messages,
                                             options: AICompletionOptions(maxTokens: 77), stream: false)
        XCTAssertEqual(chat.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/fixture-model:generateContent")
    }

    func testDeepOverridesPreserveSiblingsAndUserHeadersOverrideAuth() throws {
        let provider = try resolved("ollama-cloud") {
            $0.extraBodyJSON = "{\"options\":{\"num_predict\":123,\"seed\":42},\"keep_alive\":\"5m\"}"
            $0.headers = [HeaderEntry(name: "authorization", value: "Bearer custom"),
                          HeaderEntry(name: "X-Secret", isSecret: true)]
        }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(temperature: 0.2, maxTokens: 77), stream: false)
        let json = try body(request)
        XCTAssertEqual(json["options"] as? NSDictionary, ["num_predict": 123, "seed": 42, "temperature": 0.2] as NSDictionary)
        XCTAssertEqual(json["keep_alive"] as? String, "5m")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer custom")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Secret"), "header-secret")
    }

    func testMalformedOrNonObjectOverridesFailBeforeHTTP() throws {
        for extra in ["{broken", "[]", "\"scalar\""] {
            let provider = try resolved("openai") { $0.extraBodyJSON = extra }
            XCTAssertThrowsError(try AIRequestBuilder.build(provider, messages: messages,
                                                            options: AICompletionOptions(), stream: false)) { error in
                guard let failure = error as? AIError, case .notConfigured = failure else {
                    return XCTFail("expected invalid configuration, got \(error)")
                }
            }
        }
    }

    func testLearnedConstraintsWinOverAdvancedOverrides() throws {
        let provider = try resolved("openai") {
            $0.extraBodyJSON = "{\"temperature\":0.9,\"max_tokens\":222,\"stream_options\":{\"include_usage\":true},\"tools\":[]}"
        }
        var quirks = AIRequestQuirks()
        quirks.omitted = ["temperature", "stream_options"]
        quirks.tokenField = "max_completion_tokens"
        quirks.withoutTools = true
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(maxTokens: 77), stream: true, quirks: quirks)
        let json = try body(request)
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["stream_options"])
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["max_tokens"])
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 222)
    }

    func testThinkingAdjustmentUsesSupportedLevelAndPreservesLargerCap() throws {
        var quirks = AIRequestQuirks()
        quirks.thinkLevel = "low"
        let provider = try resolved("ollama-local") { $0.extraBodyJSON = "{\"think\":false}" }
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(maxTokens: 8192, purpose: .quick),
                                                stream: false, quirks: quirks)
        let json = try body(request)
        XCTAssertEqual(json["think"] as? String, "low")
        XCTAssertEqual((json["options"] as? [String: Any])?["num_predict"] as? Int, 8192)
        let small = try AIRequestBuilder.build(provider, messages: messages,
                                              options: AICompletionOptions(maxTokens: 77), stream: false, quirks: quirks)
        XCTAssertEqual((try body(small)["options"] as? [String: Any])?["num_predict"] as? Int, 4096)
    }

    func testParameterRejectionChoosesOnlyRelevantAdjustment() throws {
        struct Fixture {
            let message: String
            var tokenField: String?
            var thinkLevel: String?
            var omitted: Set<String> = []
            var withoutTools = false
        }
        let cases = [
            Fixture(message: "Unsupported parameter: temperature", omitted: ["temperature"]),
            Fixture(message: "stream_options is unsupported", omitted: ["stream_options"]),
            Fixture(message: "Use max_completion_tokens instead of max_tokens", tokenField: "max_completion_tokens"),
            Fixture(message: "max_completion_tokens is unsupported", tokenField: "max_tokens"),
            Fixture(message: "think accepts only low", thinkLevel: "low"),
            Fixture(message: "think is unsupported", omitted: ["think"]),
            Fixture(message: "This model does not support tools", withoutTools: true),
        ]
        for fixture in cases {
            let adjustment = try XCTUnwrap(AIQuirkCache.adjustment(message: fixture.message, current: AIRequestQuirks()))
            XCTAssertEqual(adjustment.tokenField, fixture.tokenField, fixture.message)
            XCTAssertEqual(adjustment.thinkLevel, fixture.thinkLevel, fixture.message)
            XCTAssertEqual(adjustment.omitted, fixture.omitted, fixture.message)
            XCTAssertEqual(adjustment.withoutTools, fixture.withoutTools, fixture.message)
        }
        XCTAssertNil(AIQuirkCache.adjustment(message: "Invalid API key", current: AIRequestQuirks()))
    }

    func testTimeoutSelectionUsesEndpointAndHonorsExplicitOverrides() throws {
        let remote = try resolved("openai") {
            $0.firstTokenTimeout = 0
            $0.requestTimeout = 0
            $0.idleTimeout = 0
        }
        let localProxy = try resolved("openai") {
            $0.baseURL = "http://localhost:8080/v1"
            $0.firstTokenTimeout = 0
        }
        let ollama = try resolved("ollama-cloud") { $0.firstTokenTimeout = 0 }
        XCTAssertEqual(AITimeouts(remote).firstToken, 60)
        XCTAssertEqual(AITimeouts(localProxy).firstToken, 300)
        XCTAssertEqual(AITimeouts(ollama).firstToken, 300)
        let explicit = try resolved("openai") {
            $0.firstTokenTimeout = 17
            $0.idleTimeout = 23
            $0.requestTimeout = 41
        }
        let timeouts = AITimeouts(explicit)
        XCTAssertEqual(timeouts.firstToken, 17)
        XCTAssertEqual(timeouts.idle, 23)
        XCTAssertEqual(timeouts.request, 41)
        let request = try AIRequestBuilder.build(explicit, messages: messages, options: AICompletionOptions(), stream: false)
        XCTAssertEqual(request.timeoutInterval, 41)
        XCTAssertEqual(timeouts.configuration().timeoutIntervalForRequest, 41)
        XCTAssertEqual(timeouts.configuration().timeoutIntervalForResource, 41)
    }

    func testRetryDelayRejectsHTTPTimeoutAndPermanentErrors() {
        for status in [400, 401, 403, 404, 408, 422] {
            XCTAssertNil(AITransportClient.retryDelay(status: status, retryAfter: "1", attempt: 0), "HTTP \(status)")
        }
    }

    func testRetryAfterAndFallbackBackoffApplyOnlyToTransientHTTPFailures() throws {
        XCTAssertEqual(AITransportClient.retryDelay(status: 429, retryAfter: "3", attempt: 0), 3)
        XCTAssertEqual(AITransportClient.retryDelay(status: 503, retryAfter: "-2", attempt: 0), 0)
        XCTAssertEqual(AITransportClient.retryDelay(status: 503, retryAfter: "Wed, 01 Jan 2020 00:00:00 GMT", attempt: 0), 0)
        for (attempt, bounds) in [0: 0.5...0.75, 1: 1.0...1.25] {
            let delay = try XCTUnwrap(AITransportClient.retryDelay(status: 502, retryAfter: "invalid", attempt: attempt))
            XCTAssertGreaterThanOrEqual(delay, bounds.lowerBound)
            XCTAssertLessThanOrEqual(delay, bounds.upperBound)
        }
    }

    func testProviderFailureIncludesActionableContextWithoutSecrets() throws {
        let provider = try resolved("openai") {
            $0.baseURL = "https://proxy.example/v1?key=private-query"
            $0.headers = [HeaderEntry(name: "X-Secret", isSecret: true)]
        }
        let data = Data("{\"error\":{\"message\":\"Rejected fixture-secret and header-secret\"}}".utf8)
        let failure = AIErrorMapper.failure(resolved: provider, status: 401, data: data)
        XCTAssertEqual(failure.status, 401)
        XCTAssertEqual(failure.message, "Rejected [REDACTED] and [REDACTED]")
        XCTAssertTrue(failure.requestURLDisplay.contains("proxy.example"))
        XCTAssertFalse(failure.requestURLDisplay.contains("private-query"))
        XCTAssertFalse(failure.description.contains("fixture-secret"))
        XCTAssertFalse(failure.description.contains("header-secret"))
        XCTAssertTrue(failure.hint.lowercased().contains("api key"))
    }

    func testNetworkTimeoutRetainsContextWithoutHTTPStatus() throws {
        let provider = try resolved("ollama-local")
        let error = AIErrorMapper.network(error: URLError(.timedOut), resolved: provider)
        guard case .provider(let failure) = error else { return XCTFail("expected contextual provider error") }
        XCTAssertNil(failure.status)
        XCTAssertEqual(failure.requestURLDisplay, "localhost:11434/api/chat")
        XCTAssertTrue(failure.hint.lowercased().contains("timeout"))
    }

    func testToolsUseFamilySpecificSchemasAndNativeGeminiDoesNotAdvertiseThem() throws {
        let tool = RecordingTool(name: "fixture_tool")
        let schema: [String: Any] = ["type": "object", "properties": ["input": ["type": "string"]], "required": [String]()]
        let function: [String: Any] = ["name": "fixture_tool", "description": "A test tool.", "parameters": schema]
        for id in ["openai", "ollama-local", "azure-deployments", "azure-v1"] {
            let provider = try resolved(id) {
                if id.hasPrefix("azure") { $0.baseURL = "https://fixture.openai.azure.com"; $0.deployment = "alias" }
            }
            let request = try AIRequestBuilder.build(provider, messages: messages, tools: [tool],
                                                    options: AICompletionOptions(), stream: false)
            XCTAssertEqual(try body(request)["tools"] as? NSArray,
                           [["type": "function", "function": function]] as NSArray, id)
        }
        let anthropic = try AIRequestBuilder.build(resolved("anthropic"), messages: messages, tools: [tool],
                                                  options: AICompletionOptions(), stream: false)
        XCTAssertEqual(try body(anthropic)["tools"] as? NSArray,
                       [["name": "fixture_tool", "description": "A test tool.", "input_schema": schema]] as NSArray)
        let gemini = try AIRequestBuilder.build(resolved("gemini"), messages: messages, tools: [tool],
                                               options: AICompletionOptions(), stream: false)
        XCTAssertNil(try body(gemini)["tools"])
    }

    func testNestedOllamaSamplingOverrideCannotReintroduceRejectedTemperature() throws {
        let provider = try resolved("ollama-local") {
            $0.extraBodyJSON = "{\"options\":{\"temperature\":0.9,\"seed\":42}}"
        }
        var quirks = AIRequestQuirks()
        quirks.omitted = ["temperature"]
        let request = try AIRequestBuilder.build(provider, messages: messages,
                                                options: AICompletionOptions(temperature: 0.2, maxTokens: 77),
                                                stream: false, quirks: quirks)
        XCTAssertEqual(try body(request)["options"] as? NSDictionary,
                       ["num_predict": 77, "seed": 42] as NSDictionary)
    }

    func testQuirkCacheIsIsolatedByProviderInstanceAndModel() throws {
        let provider = try resolved("openai")
        var quirks = AIRequestQuirks()
        quirks.omitted = ["temperature"]
        AIQuirkCache.put(quirks, for: provider)
        XCTAssertEqual(AIQuirkCache.get(provider).omitted, ["temperature"])

        var instance = provider.instance
        instance.model = "another-model"
        let anotherModel = ResolvedProvider(descriptor: provider.descriptor, instance: instance,
                                            apiKey: provider.apiKey, secretHeaders: [:])
        XCTAssertTrue(AIQuirkCache.get(anotherModel).omitted.isEmpty)
        let anotherInstance = try resolved("openai")
        XCTAssertTrue(AIQuirkCache.get(anotherInstance).omitted.isEmpty)
    }

    func testRejectedToolsBecomeReadableHistoryWithoutWireToolRoles() throws {
        let call = AIToolCall(id: "call-1", toolName: "fixture_tool", arguments: ["input": "query"])
        let history = [
            AIMessage(role: .assistant, content: AIToolCallsSentinel.encode([call])),
            AIMessage(role: .user, content: AIToolResultSentinel.encode(id: "call-1", toolName: "fixture_tool", result: "found")),
        ]
        var quirks = AIRequestQuirks()
        quirks.withoutTools = true
        let request = try AIRequestBuilder.build(resolved("openai"), messages: history,
                                                tools: [RecordingTool(name: "fixture_tool")],
                                                options: AICompletionOptions(), stream: false, quirks: quirks)
        let json = try body(request)
        XCTAssertNil(json["tools"])
        let wired = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(wired.map { $0["role"] as? String }, ["assistant", "user"])
        XCTAssertTrue((wired[0]["content"] as? String)?.contains("fixture_tool") == true)
        XCTAssertTrue((wired[1]["content"] as? String)?.contains("found") == true)
        XCTAssertNil(wired[0]["tool_calls"])
        XCTAssertNil(wired[1]["tool_call_id"])
    }

    func testOllamaQuickThinkDecisionTable() throws {
        func options(_ purpose: AICompletionPurpose, _ tokens: Int = 32) -> AICompletionOptions {
            AICompletionOptions(maxTokens: tokens, purpose: purpose)
        }
        func predict(_ request: URLRequest) throws -> Int? { (try body(request)["options"] as? [String: Any])?["num_predict"] as? Int }
        var capable = AIRequestQuirks()
        capable.thinkingCapable = true
        let local = try resolved("ollama-local")
        let quick = try AIRequestBuilder.build(local, messages: messages, options: options(.quick), stream: false, quirks: capable)
        XCTAssertEqual(try body(quick)["think"] as? String, "low")
        XCTAssertEqual(try predict(quick), 1024)
        let big = try AIRequestBuilder.build(local, messages: messages, options: options(.quick, 3000), stream: false, quirks: capable)
        XCTAssertEqual(try predict(big), 3000)
        var plain = AIRequestQuirks()
        plain.thinkingCapable = false
        let notThinking = try AIRequestBuilder.build(local, messages: messages, options: options(.quick), stream: false, quirks: plain)
        XCTAssertEqual(try body(notThinking)["think"] as? Bool, false)
        XCTAssertEqual(try predict(notThinking), 32)
        let chat = try AIRequestBuilder.build(local, messages: messages, options: options(.chat), stream: false, quirks: capable)
        XCTAssertNil(try body(chat)["think"])
        let explicit = try resolved("ollama-local") { $0.params.thinkOllama = false }
        let wins = try AIRequestBuilder.build(explicit, messages: messages, options: options(.quick), stream: false, quirks: capable)
        XCTAssertEqual(try body(wins)["think"] as? Bool, false)
        XCTAssertEqual(try predict(wins), 32)
    }

    func testOllamaThinkRejectionLadderStates() throws {
        let local = try resolved("ollama-local")
        var capable = AIRequestQuirks()
        capable.thinkingCapable = true
        var off = capable
        off.thinkOverride = .off
        let offRequest = try AIRequestBuilder.build(local, messages: messages,
                                                   options: AICompletionOptions(maxTokens: 32, purpose: .quick), stream: false, quirks: off)
        XCTAssertEqual(try body(offRequest)["think"] as? Bool, false)
        var on = capable
        on.thinkOverride = .on
        let onRequest = try AIRequestBuilder.build(local, messages: messages,
                                                  options: AICompletionOptions(maxTokens: 32, purpose: .quick), stream: false, quirks: on)
        XCTAssertEqual(try body(onRequest)["think"] as? Bool, true)
        XCTAssertGreaterThanOrEqual((try body(onRequest)["options"] as? [String: Any])?["num_predict"] as? Int ?? 0, 2048)
        XCTAssertTrue(AIReasoningLeak.looksLikeReasoning("The user has sent me a message that appears to be"))
        XCTAssertFalse(AIReasoningLeak.looksLikeReasoning("Quick Brown Fox Story"))
    }

}
