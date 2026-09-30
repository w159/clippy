import XCTest
@testable import Clippy

final class AIResponseParserTests: XCTestCase {
    func testVisibleTextAcrossFamilies() throws {
        let cases: [(WireFamily, String)] = [
            (.openaiChat, #"{"choices":[{"message":{"content":"Hello"}}]}"#),
            (.azureV1, #"{"choices":[{"message":{"content":"Hello"}}]}"#),
            (.azureDeployments, #"{"choices":[{"message":{"content":"Hello"}}]}"#),
            (.ollamaChat, #"{"message":{"content":"Hello"},"done":true}"#),
            (.anthropicMessages, #"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Hel"},{"type":"text","text":"lo"}]}"#),
            (.geminiNative, #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"private"},{"text":"Hello"}]}}]}"#),
        ]
        for (family, json) in cases {
            guard case .text(let text) = try AIResponseParser.parseTurn(Data(json.utf8), family: family) else { return XCTFail("Expected text") }
            XCTAssertEqual(text, "Hello")
        }
    }

    func testToolCallsDoNotDependOnFinishReason() throws {
        let json = #"{"choices":[{"finish_reason":"stop","message":{"content":"","tool_calls":[{"id":"one","function":{"name":"find","arguments":"{\"query\":\"clip\"}"}}]}}]}"#
        guard case .toolCalls(let calls) = try AIResponseParser.parseTurn(Data(json.utf8), family: .openaiChat) else { return XCTFail("Discarded calls") }
        XCTAssertEqual(calls.first?.toolName, "find")
        XCTAssertEqual(calls.first?.arguments["query"] as? String, "clip")
        let anthropic = #"{"stop_reason":"end_turn","content":[{"type":"tool_use","id":"one","name":"find","input":{"query":"clip"}}]}"#
        guard case .toolCalls(let native) = try AIResponseParser.parseTurn(Data(anthropic.utf8), family: .anthropicMessages) else { return XCTFail("Discarded native tools") }
        XCTAssertEqual(native.first?.toolName, "find")
    }

    func testThinkingOnlyLengthIsSpecificFailure() {
        for (family, json) in [
            (WireFamily.ollamaChat, #"{"message":{"content":"","thinking":"working"},"done_reason":"length"}"#),
            (.openaiChat, #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#),
            (.anthropicMessages, #"{"content":[{"type":"thinking","thinking":"working"}],"stop_reason":"max_tokens"}"#),
            (.geminiNative, #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"working"}]},"finishReason":"MAX_TOKENS"}]}"#),
        ] {
            XCTAssertThrowsError(try AIResponseParser.parseTurn(Data(json.utf8), family: family)) { XCTAssertEqual($0 as? AIError, .outputLimitDuringReasoning) }
        }
    }

    func testStreamErrorsCannotBecomeSuccess() throws {
        for family in [WireFamily.openaiChat, .anthropicMessages, .azureV1, .azureDeployments, .geminiNative] {
            var parser = AIResponseStreamParser(family: family)
            XCTAssertThrowsError(try parser.consume(line: #"data: {"type":"error","error":{"message":"quota"}}"#))
        }
        var ollama = AIResponseStreamParser(family: .ollamaChat)
        XCTAssertThrowsError(try ollama.consume(line: #"{"error":"model vanished"}"#))
        var sse = AIResponseStreamParser(family: .openaiChat)
        _ = try sse.consume(line: "event: error")
        XCTAssertThrowsError(try sse.consume(line: #"data: {"message":"interrupted"}"#))
    }

    func testThinkingAndTextStreamFixtures() throws {
        let cases: [(WireFamily, [String])] = [
            (.openaiChat, [#"data: {"choices":[{"delta":{"reasoning_content":"Thinking"}}]}"#, #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#]),
            (.ollamaChat, [#"{"message":{"thinking":"Thinking"}}"#, #"{"message":{"content":"Hello"},"done":true}"#]),
            (.anthropicMessages, [
                #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Thinking"}}"#,
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#]),
            (.geminiNative, [#"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"Thinking"},{"text":"Hello"}]}}]}"#]),
        ]
        for (family, lines) in cases {
            var parser = AIResponseStreamParser(family: family)
            var text = ""
            var thinking = ""
            for line in lines {
                for event in try parser.consume(line: line) {
                    switch event {
                    case .textDelta(let delta): text += delta
                    case .thinkingDelta(let delta): thinking += delta
                    default: break
                    }
                }
            }
            _ = try parser.finish()
            XCTAssertEqual(text, "Hello")
            XCTAssertEqual(thinking, "Thinking")
        }
    }

    func testStreamReasoningExhaustion() throws {
        var parser = AIResponseStreamParser(family: .ollamaChat)
        _ = try parser.consume(line: #"{"message":{"thinking":"long thought","content":""},"done":true,"done_reason":"length"}"#)
        XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? AIError, .outputLimitDuringReasoning) }
    }
    func testSignedThinkingReplaysWithToolTurns() throws {
        let json = #"{"content":[{"type":"thinking","thinking":"work","signature":"signed"},{"type":"tool_use","id":"call","name":"find","input":{}}]}"#
        guard case .toolCalls(let calls) = try AIResponseParser.parseTurn(Data(json.utf8), family: .anthropicMessages) else { return XCTFail("Expected calls") }
        let sentinel = AIToolCallsSentinel.encode(calls)
        let messages = AIMessageBuilder.anthropic([AIMessage(role: .assistant, content: sentinel)])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["signature"] as? String, "signed")
        XCTAssertEqual(content.last?["type"] as? String, "tool_use")
    }

    func testIncompleteToolArgumentsDoNotExecuteAsEmptyObject() throws {
        var parser = AIResponseStreamParser(family: .openaiChat)
        _ = try parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"one","function":{"name":"find","arguments":"{\"query\": "}}]}}]}"#)
        XCTAssertThrowsError(try parser.finish())
    }

    func testOllamaMultipleToolChunksAndUsageOnlyTerminal() throws {
        var parser = AIResponseStreamParser(family: .ollamaChat)
        _ = try parser.consume(line: #"{"message":{"tool_calls":[{"function":{"name":"first","arguments":{"a":1}}}]}}"#)
        _ = try parser.consume(line: #"{"message":{"tool_calls":[{"function":{"name":"second","arguments":{"b":2}}}]}}"#)
        _ = try parser.consume(line: #"{"done":true,"prompt_eval_count":12,"eval_count":34}"#)
        let events = try parser.finish()
        let calls = events.compactMap { event -> [AIToolCall]? in
            if case .toolCalls(let calls) = event { return calls }
            return nil
        }.flatMap { $0 }
        XCTAssertEqual(calls.map(\.toolName), ["first", "second"])
        XCTAssertEqual(Set(calls.map(\.id)).count, 2)
        let usage = events.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { return usage }
            return nil
        }.first
        XCTAssertEqual(usage, AIUsage(promptTokens: 12, completionTokens: 34))
    }

    func testErrorContextUsesActualNativeStreamEndpointWithoutQuery() throws {
        let instance = ProviderInstance(descriptorID: "gemini", name: "Gemini", model: "test")
        let resolved = ResolvedProvider(descriptor: ProviderCatalog.descriptor(id: "gemini")!, instance: instance, apiKey: "secret", secretHeaders: [:])
        let failure = AIErrorMapper.failure(resolved: resolved, status: 404, data: Data(#"{"error":{"message":"missing"}}"#.utf8), purpose: .stream)
        XCTAssertTrue(failure.requestURLDisplay.hasSuffix("/models/test:streamGenerateContent"))
        XCTAssertFalse(failure.requestURLDisplay.contains("?"))
        XCTAssertTrue(AIErrorMapper.timeout("First token", resolved: resolved, purpose: .stream).localizedDescription.contains("streamGenerateContent"))
    }


    func testOllamaThinkingIsNeverTheAnswer() throws {
        let limited = #"{"message":{"content":"","thinking":"The user has sent a message"},"done":true,"done_reason":"length"}"#
        XCTAssertThrowsError(try AIResponseParser.parseTurn(Data(limited.utf8), family: .ollamaChat)) {
            XCTAssertEqual($0 as? AIError, .outputLimitDuringReasoning)
        }
        let stopped = #"{"message":{"content":"","thinking":"Reasoning only"},"done":true,"done_reason":"stop"}"#
        XCTAssertThrowsError(try AIResponseParser.parseTurn(Data(stopped.utf8), family: .ollamaChat)) {
            XCTAssertEqual($0 as? AIError, .empty)
        }
        var parser = AIResponseStreamParser(family: .ollamaChat)
        let events = try parser.consume(line: #"{"message":{"content":"","thinking":"Reasoning"}}"#)
        XCTAssertEqual(events.count, 1)
        guard case .thinkingDelta("Reasoning") = events[0] else { return XCTFail("Thinking must only be a thinking event") }
    }

}
