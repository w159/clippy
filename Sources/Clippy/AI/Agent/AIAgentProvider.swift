import Foundation

// MARK: - Agent-capable provider protocol

/// A provider that supports tool/function calling. Extends the base `AIProvider`
/// with a single agentic call: given messages and tools, return either a final
/// text answer or a list of tool calls the model wants to make.
///
/// API docs consulted:
///   OpenAI  — https://platform.openai.com/docs/guides/function-calling (2025-05 version)
///   Anthropic — https://docs.anthropic.com/en/docs/tool-use (2024-11 / anthropic-version 2023-06-01)
///   Ollama  — https://ollama.com/blog/tool-support (/api/chat, July 2024)
///   Azure   — OpenAI-compatible chat completions (api-version 2024-10-21)
protocol AIAgentProvider: AIProvider {
    /// One agentic turn. Returns `.text` when the model has a final answer, or
    /// `.toolCalls` with the list of calls the model wants to make.
    func completeWithTools(
        _ messages: [AIMessage],
        tools: [AITool],
        options: AICompletionOptions
    ) async throws -> AIAgentTurn

    /// Streaming variant: yields text deltas live, then any tool calls, then `.done`.
    func streamWithTools(_ messages: [AIMessage], tools: [AITool],
                         options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error>
}

extension AIAgentProvider {
    /// Plain streaming is a tool-less agentic stream.
    func stream(_ messages: [AIMessage], options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        streamWithTools(messages, tools: [], options: options)
    }
}

// MARK: - Turn result

enum AIAgentTurn {
    case text(String)
    case toolCalls([AIToolCall])
}

/// One tool invocation requested by the model.
///
/// `@unchecked Sendable`: `arguments` is the JSON tree decoded from the provider's
/// reply (strings, numbers, arrays, dictionaries) and is never mutated afterwards.
struct AIToolCall: Equatable, @unchecked Sendable {
    /// Provider-assigned call id (used by OpenAI/Azure/Anthropic to correlate
    /// the tool_result back to the tool_use block).
    let id: String
    let toolName: String
    /// JSON-decoded argument dictionary.
    let arguments: [String: Any]
    var replayBlocks: Data? = nil

    static func == (lhs: AIToolCall, rhs: AIToolCall) -> Bool {
        lhs.id == rhs.id && lhs.toolName == rhs.toolName
    }
}

