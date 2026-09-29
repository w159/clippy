import Foundation

/// One tool call shown inside an assistant bubble (AI-12 transparency).
struct AssistantToolStep: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    /// Pretty-printed arguments; empty for synthetic steps such as "Retrying".
    var arguments: String = ""
    var result: String?
    var isRunning: Bool
}

/// One display turn in the assistant conversation. Display only: what the model
/// sees lives in `AITranscript`.
struct AssistantMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    /// When true this assistant message carries an error, not a normal reply.
    var isError: Bool = false
    var toolSteps: [AssistantToolStep] = []
    /// Token usage for the turn, when the provider reported it.
    var usage: AIUsage?
    /// For user messages: transcript length before this turn, so Retry can roll back.
    var transcriptStart: Int?
}
