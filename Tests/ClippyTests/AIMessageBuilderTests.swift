import XCTest
@testable import Clippy

final class AIMessageBuilderTests: XCTestCase {
    private let resultMessage = AIMessage(
        role: .user, content: AIToolResultSentinel.encode(id: "c1", toolName: "search_clips", result: "found"))
    private let callsMessage = AIMessage(
        role: .assistant,
        content: AIToolCallsSentinel.encode([AIToolCall(id: "c1", toolName: "search_clips", arguments: ["query": "x"])]))

    func testOpenAIConvertsResultAndCalls() {
        let wired = AIMessageBuilder.openAI([callsMessage, resultMessage])
        XCTAssertEqual(wired[1]["role"] as? String, "tool")
        XCTAssertEqual(wired[1]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(wired[1]["content"] as? String, "found")
        let calls = wired[0]["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.first?["id"] as? String, "c1")
        let fn = calls?.first?["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "search_clips")
        XCTAssertEqual(fn?["arguments"] as? String, "{\"query\":\"x\"}")
    }

    func testOllamaConvertsResultWithoutCallID() {
        let wired = AIMessageBuilder.ollama([callsMessage, resultMessage])
        XCTAssertEqual(wired[1]["role"] as? String, "tool")
        XCTAssertNil(wired[1]["tool_call_id"])
        XCTAssertEqual(wired[1]["content"] as? String, "found")
        let fn = (wired[0]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        XCTAssertEqual((fn?["arguments"] as? [String: Any])?["query"] as? String, "x")
    }

    func testAnthropicGroupsResultsAndDropsSystem() {
        let second = AIMessage(role: .user, content: AIToolResultSentinel.encode(id: "c2", toolName: "t", result: "r2"))
        let wired = AIMessageBuilder.anthropic([
            AIMessage(role: .system, content: "sys"), callsMessage, resultMessage, second,
        ])
        XCTAssertEqual(wired.count, 2)
        let use = (wired[0]["content"] as? [[String: Any]])?.first
        XCTAssertEqual(use?["type"] as? String, "tool_use")
        XCTAssertEqual(use?["id"] as? String, "c1")
        let results = wired[1]["content"] as? [[String: Any]]
        XCTAssertEqual(results?.map { $0["tool_use_id"] as? String }, ["c1", "c2"])
    }

    func testPlainTextFoldsSentinelsSoNoRawSentinelReachesAModel() {
        let plain = AIMessageBuilder.plainText([callsMessage, resultMessage, AIMessage(role: .user, content: "hi")])
        for message in plain {
            XCTAssertFalse(message.content.contains("__tool_result__"))
            XCTAssertFalse(message.content.contains("__tool_calls__"))
        }
        XCTAssertEqual(plain[1].role, .user)
        XCTAssertTrue(plain[1].content.contains("found"))
        XCTAssertTrue(plain[0].content.contains("search_clips"))
        XCTAssertEqual(plain[2].content, "hi")
    }

    func testCallsSentinelRoundTrips() {
        let calls = AIToolCallsSentinel.decode(callsMessage.content)
        XCTAssertEqual(calls?.first?.toolName, "search_clips")
        XCTAssertEqual(calls?.first?.arguments["query"] as? String, "x")
        XCTAssertNil(AIToolCallsSentinel.decode("plain"))
    }

    func testOllamaOptionsCarryNumPredict() {
        let options = OllamaOptions.payload(AICompletionOptions(temperature: 0.2, maxTokens: 77))
        XCTAssertEqual(options["num_predict"] as? Int, 77)
        XCTAssertEqual(options["temperature"] as? Double, 0.2)
    }

    func testOnlyAppleIntelligenceLacksTools() {
        XCTAssertFalse(AIProviderKind.appleIntelligence.supportsTools)
        for kind in AIProviderKind.allCases where kind != .appleIntelligence {
            XCTAssertTrue(kind.supportsTools)
        }
    }
}
