import Foundation

/// One low-level event from a provider's streamed response.
enum AIStreamEvent: Sendable {
    case thinkingDelta(String)
    case notice(String)
    case textDelta(String)
    /// The provider revised text it already streamed: swap `old` (a suffix of the
    /// text emitted so far) for `new` instead of appending.
    case textReplace(old: String, new: String)
    /// Token counts, when the provider reports them. May arrive more than once.
    case usage(AIUsage)
    case toolCalls([AIToolCall])
    case done
}

/// One high-level event from the streaming agent loop, consumed by the UI.
enum AIAgentEvent: Sendable {
    case notice(String)
    case textDelta(String)
    case textReplace(old: String, new: String)
    /// A tool call is about to run. Carries the full call so the UI can show
    /// arguments (AI-12 tool transparency).
    case toolCall(AIToolCall)
    /// The result the tool returned (already truncated by the tool), for transcript replay.
    case toolResult(id: String, name: String, result: String)
    /// Usage for one provider call; the UI sums these across the turn.
    case usage(AIUsage)
    case toolStarted(String)
    case toolFinished(String)
}

