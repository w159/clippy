import Foundation

/// Role in a chat exchange. Anthropic keeps `system` out of the message list, so
/// providers that need it split it out themselves.
enum AIRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct AIMessage: Equatable, Sendable {
    let role: AIRole
    let content: String
}

enum AICompletionPurpose: Sendable { case quick, chat }

struct AICompletionOptions: Sendable {
    var temperature: Double? = nil
    var maxTokens: Int = 1024
    var purpose: AICompletionPurpose = .chat
}

enum AIError: LocalizedError, Equatable {
    case notConfigured(String)
    case badURL(String)
    case http(Int, String)
    case decoding(String)
    case empty
    case provider(AIRequestFailure)
    case outputLimitDuringReasoning

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return "AI is not configured: \(why)"
        case .badURL(let url): return "Invalid endpoint URL: \(url)"
        case .http(let code, let body):
            let snippet = body.prefix(300)
            return "Provider returned HTTP \(code): \(snippet)"
        case .decoding(let why): return "Could not read the provider response: \(why)"
        case .provider(let failure): return failure.description
        case .outputLimitDuringReasoning: return "Output limit reached while thinking. Increase the output token budget or disable thinking for quick actions."
        case .empty: return "The provider returned an empty response."
        }
    }
}

/// One chat-completion call. Every backend (Ollama, OpenAI, Anthropic, Azure AI
/// Foundry) implements this; the rest of the app only depends on this protocol,
/// which keeps the agentic features testable with a mock.
protocol AIProvider: Sendable {
    func complete(_ messages: [AIMessage], options: AICompletionOptions) async throws -> String
    /// Streamed variant of `complete` (text deltas only). Providers without real
    /// streaming inherit a default that yields the whole reply as one delta.
    func stream(_ messages: [AIMessage], options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error>
}

extension AIProvider {
    func stream(_ messages: [AIMessage], options: AICompletionOptions) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await complete(messages, options: options)))
                    continuation.yield(.done)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

