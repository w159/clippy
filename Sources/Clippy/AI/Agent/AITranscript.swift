import Foundation

/// The structured conversation the model sees (AI-05), kept separate from the
/// display messages. Error bubbles never enter it, and tool turns keep their
/// calls and results so a replay is exactly what the model produced and saw.
struct AITranscript: Codable, Equatable {
    struct Call: Codable, Equatable {
        let id: String
        let name: String
        /// Arguments as a JSON object string (Codable-friendly).
        let argumentsJSON: String
        var replayBlocks: Data? = nil
    }

    enum Entry: Codable, Equatable {
        case user(String)
        case assistant(String)
        case toolCall(Call)
        case toolResult(id: String, name: String, result: String)
    }

    private(set) var entries: [Entry] = []

    var count: Int { entries.count }

    mutating func append(_ entry: Entry) { entries.append(entry) }

    mutating func appendToolCall(_ call: AIToolCall) {
        append(.toolCall(Call(id: call.id, name: call.toolName,
                              argumentsJSON: AIToolCallsSentinel.jsonString(call.arguments), replayBlocks: call.replayBlocks)))
    }

    /// Drop everything from `index` on. Used to roll back a failed turn or retry.
    mutating func truncate(to index: Int) {
        guard index >= 0, index < entries.count else { return }
        entries.removeSubrange(index...)
    }

    /// True when any tool call or result was recorded at or after `index`.
    func hasToolActivity(since index: Int) -> Bool {
        entries.dropFirst(max(0, index)).contains {
            switch $0 {
            case .toolCall, .toolResult: return true
            default: return false
            }
        }
    }

    /// Keep only the newest `limit` entries, never starting on an orphaned tool
    /// result (a result without its call is invalid for every provider).
    mutating func trim(toLast limit: Int) {
        guard entries.count > limit else { return }
        entries.removeFirst(entries.count - limit)
        while let first = entries.first {
            if case .user = first { break }
            entries.removeFirst()
        }
    }

    /// Provider messages for the next request.
    func providerMessages() -> [AIMessage] {
        entries.map { entry in
            switch entry {
            case .user(let text):
                return AIMessage(role: .user, content: text)
            case .assistant(let text):
                return AIMessage(role: .assistant, content: text)
            case .toolCall(let call):
                let args = (call.argumentsJSON.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                return AIMessage(role: .assistant, content: AIToolCallsSentinel.encode(
                    [AIToolCall(id: call.id, toolName: call.name, arguments: args, replayBlocks: call.replayBlocks)]))
            case .toolResult(let id, let name, let result):
                return AIMessage(role: .user,
                                 content: AIToolResultSentinel.encode(id: id, toolName: name, result: result))
            }
        }
    }
}
