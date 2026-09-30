import Combine
import Foundation

/// Background AI failures without retaining prompts, clipboard content or response bodies.
@MainActor
final class AIHealth: ObservableObject {
    static let shared = AIHealth()

    @Published private(set) var lastFailure: String?

    func record(_ error: Error) {
        let message: String
        switch error {
        case AIError.notConfigured:
            message = "AI provider is not configured. Check AI Settings."
        case AIError.badURL:
            message = "AI provider endpoint is invalid. Check AI Settings."
        case AIError.http(let status, _):
            message = "AI provider request failed (HTTP \(status))."
        case AIError.provider(let failure):
            if let status = failure.status {
                message = "AI provider request failed (HTTP \(status)). Check AI Settings."
            } else {
                message = "AI provider connection failed. Check AI Settings."
            }
        case AIError.decoding:
            message = "AI provider returned an unreadable response."
        case AIError.empty:
            message = "AI provider returned an empty response."
        case AIError.outputLimitDuringReasoning:
            message = "AI output limit reached while thinking. Increase the token budget."
        case is CancellationError:
            message = "AI request was interrupted."
        case let error as URLError:
            message = "AI network request failed (code \(error.code.rawValue))."
        default:
            // Arbitrary errors can echo clipboard text, file paths or credentials.
            message = "AI operation failed. Check provider settings and try again."
        }
        lastFailure = message
        ClippyLog.error(message, category: ClippyLog.ai)
    }
}
