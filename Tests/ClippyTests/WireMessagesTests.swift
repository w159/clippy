import XCTest
@testable import Clippy

final class WireMessagesTests: XCTestCase {

    // MARK: - Tool-result message

    func testToolResultMessageIsWiredCorrectly() {
        // Encode a tool result via the sentinel used by the agent loop.
        let encoded = AIToolResultSentinel.encode(id: "abc", toolName: "foo", result: "bar")
        let msg = AIMessage(role: .user, content: encoded)

        let wired = AIMessageBuilder.openAI([msg])

        XCTAssertEqual(wired.count, 1)
        let dict = wired[0]
        XCTAssertEqual(dict["role"] as? String, "tool",
                       "sentinel content must map to role:\"tool\"")
        XCTAssertEqual(dict["tool_call_id"] as? String, "abc",
                       "tool_call_id must match the id passed to encode")
        XCTAssertEqual(dict["content"] as? String, "bar",
                       "content must be the raw result string, not the sentinel envelope")
    }

    // MARK: - Plain message

    func testPlainUserMessageIsNotTransformed() {
        let msg = AIMessage(role: .user, content: "hello world")

        let wired = AIMessageBuilder.openAI([msg])

        XCTAssertEqual(wired.count, 1)
        let dict = wired[0]
        XCTAssertEqual(dict["role"] as? String, "user",
                       "role must remain unchanged for a plain user message")
        XCTAssertEqual(dict["content"] as? String, "hello world",
                       "content must pass through unchanged")
        XCTAssertNil(dict["tool_call_id"],
                     "plain messages must not gain a tool_call_id key")
    }
}
