import Foundation

/// Fits a conversation into a model's context window (AI-12). Token counts are a
/// conservative characters-per-token estimate, so this is a guard rail that keeps
/// a request from failing with "context size exceeded", not an exact accounting.
enum AIContextBudget {
    /// Characters per token used for the estimate. Deliberately low (English text
    /// averages ~4) so the estimate errs toward trimming too much, not too little.
    static let charsPerToken = 3

    static func estimateTokens(_ text: String) -> Int {
        (text.count + charsPerToken - 1) / charsPerToken
    }

    /// Return `messages` trimmed to at most `budgetTokens` (estimated).
    ///
    /// Order of sacrifice: 1) oldest non-system turns are dropped whole, keeping the
    /// newest; 2) if the newest turn plus system prompt still exceeds the budget,
    /// the largest remaining message is cut to its head and tail around an explicit
    /// elision marker so the model knows content is missing.
    static func fit(_ messages: [AIMessage], budgetTokens: Int) -> [AIMessage] {
        guard budgetTokens > 0 else { return messages }
        func total(_ messages: [AIMessage]) -> Int { messages.reduce(0) { $0 + estimateTokens($1.content) } }
        var result = messages
        while total(result) > budgetTokens,
              let oldest = result.firstIndex(where: { $0.role != .system }),
              result.filter({ $0.role != .system }).count > 1 {
            result.remove(at: oldest)
        }
        let overflow = total(result) - budgetTokens
        guard overflow > 0,
              let big = result.indices.max(by: {
                  result[$0].content.count < result[$1].content.count
              }) else { return result }
        let content = result[big].content
        let marker = "\n[... content omitted to fit the model's context window ...]\n"
        let keepChars = max(0, content.count - overflow * charsPerToken - marker.count)
        let head = keepChars * 2 / 3
        let tail = keepChars - head
        result[big] = AIMessage(role: result[big].role,
                                content: String(content.prefix(head)) + marker + String(content.suffix(tail)))
        return result
    }
}
