import Foundation

/// Visual family of one transcript bubble.
enum AssistantBubbleKind: Equatable {
    case user, assistant, error
}

/// Where a bubble sits inside a run of consecutive same-kind bubbles.
enum AssistantGroupPosition: Equatable {
    case single, first, middle, last

    /// Vertical gap above a bubble at this position.
    var topSpacing: CGFloat {
        switch self {
        case .single, .first: return 12
        case .middle, .last: return 4
        }
    }
}

/// Pure display rules for the assistant transcript: labels, grouping, usage text,
/// tool-step summaries and suggested prompts. Nothing here touches views, the
/// view model or the network, so every rule is unit-testable.
enum AssistantPresentation {
    // MARK: Bubbles

    /// Bubble family for a message.
    static func kind(of message: AssistantMessage) -> AssistantBubbleKind {
        if message.isError { return .error }
        return message.role == .user ? .user : .assistant
    }

    /// Short role word spoken and shown for a bubble kind.
    static func roleLabel(for kind: AssistantBubbleKind) -> String {
        switch kind {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .error: return "Error"
        }
    }

    /// One VoiceOver label per message: role, text and the number of tool steps.
    static func accessibilityLabel(for message: AssistantMessage) -> String {
        var label = "\(roleLabel(for: kind(of: message))): \(message.text)"
        let steps = message.toolSteps.count
        if steps > 0 { label += ". \(steps) tool \(steps == 1 ? "step" : "steps")" }
        return label
    }

    /// Group position of every message, keyed by id, so runs of the same kind
    /// sit closer together than turns from different speakers.
    static func groupPositions(_ messages: [AssistantMessage]) -> [UUID: AssistantGroupPosition] {
        var result: [UUID: AssistantGroupPosition] = [:]
        for (index, message) in messages.enumerated() {
            let current = kind(of: message)
            let joinsPrevious = index > 0 && kind(of: messages[index - 1]) == current
            let joinsNext = index + 1 < messages.count && kind(of: messages[index + 1]) == current
            switch (joinsPrevious, joinsNext) {
            case (false, false): result[message.id] = .single
            case (false, true): result[message.id] = .first
            case (true, true): result[message.id] = .middle
            case (true, false): result[message.id] = .last
            }
        }
        return result
    }

    // MARK: Usage

    /// Per-turn usage line, nil when the provider reported nothing.
    static func turnUsageLabel(_ usage: AIUsage?) -> String? {
        guard let usage, !usage.isEmpty else { return nil }
        return usage.summary
    }

    /// Conversation usage line for the header, e.g. "1,292 tokens".
    static func conversationUsageLabel(_ usage: AIUsage) -> String? {
        guard !usage.isEmpty else { return nil }
        return "\(usage.totalTokens.formatted(.number)) tokens"
    }

    // MARK: Tool steps

    /// Sorted top-level argument names of a pretty-printed JSON object; never values.
    static func argumentKeys(from arguments: String) -> [String] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted()
    }

    /// Size-only description of a tool result so raw clip text is never echoed.
    static func resultSummary(_ result: String?) -> String {
        guard let result else { return "No result yet" }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty result" }
        let lines = trimmed.split(whereSeparator: \.isNewline).count
        let characters = trimmed.count
        return "\(lines) \(lines == 1 ? "line" : "lines"), \(characters.formatted(.number)) characters"
    }

    /// Title of a tool step row.
    static func stepTitle(_ step: AssistantToolStep) -> String {
        step.isRunning ? "Running \(step.name)" : "Ran \(step.name)"
    }

    /// Argument names for the row subtitle, or a fallback when none were sent.
    static func stepSubtitle(_ step: AssistantToolStep) -> String {
        let keys = argumentKeys(from: step.arguments)
        return keys.isEmpty ? "no arguments" : keys.joined(separator: ", ")
    }

    /// Lifecycle glyph of a tool step.
    enum StepStatus: Equatable { case running, done, failed }

    /// Failed when the agent loop reported a tool error; the loop prefixes these.
    static func status(of step: AssistantToolStep) -> StepStatus {
        if step.isRunning { return .running }
        guard let result = step.result else { return .done }
        return result.hasPrefix("Tool error:") || result.hasPrefix("Error:") ? .failed : .done
    }

    /// One-line summary chip for a finished call, e.g. "search_clips - 12 lines, 480 characters".
    static func chipSummary(_ step: AssistantToolStep) -> String {
        switch status(of: step) {
        case .running: return "Processing..."
        case .failed: return "\(step.name) - failed"
        case .done: return "\(step.name) - \(resultSummary(step.result))"
        }
    }

    /// Index of the step marked active in a multi-step checklist: the first running step.
    static func activeStepIndex(_ steps: [AssistantToolStep]) -> Int? {
        steps.firstIndex(where: \.isRunning)
    }

    /// Checklist header, e.g. "2 of 3 steps".
    static func checklistHeader(_ steps: [AssistantToolStep]) -> String {
        let finished = steps.filter { !$0.isRunning }.count
        return "\(finished) of \(steps.count) steps"
    }

    // MARK: Approval

    /// Choices on the inline approval card, in display order with their 1-3 key hints.
    enum ApprovalChoice: CaseIterable, Equatable {
        case allowOnce, allowAlways, deny

        var title: String {
            switch self {
            case .allowOnce: return "Allow once"
            case .allowAlways: return "Allow"
            case .deny: return "Deny"
            }
        }

        var detail: String {
            switch self {
            case .allowOnce: return "Run this call only"
            case .allowAlways: return "Run it and stop asking for this tool"
            case .deny: return "Do not run it"
            }
        }

        /// Key that picks this choice.
        var keyHint: String {
            switch self {
            case .allowOnce: return "1"
            case .allowAlways: return "2"
            case .deny: return "3"
            }
        }

        /// Choice for a typed character, nil for anything else.
        static func choice(forKey key: String) -> ApprovalChoice? { allCases.first { $0.keyHint == key } }
    }

    // MARK: Empty state and composer

    /// Prompts the current provider can actually execute. Tool prompts are hidden
    /// when the provider cannot call tools; attached-clip prompts need a clip.
    static func suggestions(toolsSupported: Bool, hasAttachedClip: Bool) -> [String] {
        var prompts: [String] = []
        if hasAttachedClip {
            prompts += ["Summarize the attached clip", "Rewrite the attached clip more concisely"]
        }
        if toolsSupported {
            prompts += ["Search my clips for meeting notes", "Summarize what I copied today",
                        "Create a clip with a bash one-liner to list files"]
        }
        if prompts.isEmpty { prompts = ["Explain what a regular expression is"] }
        return prompts
    }

    /// Spoken announcement when a turn ends; metadata only, never reply text.
    static func completionAnnouncement(for message: AssistantMessage?) -> String {
        guard let message, message.role == .assistant else { return "Assistant finished responding" }
        if message.isError { return "Assistant could not finish. An error was reported" }
        let steps = message.toolSteps.count
        return steps > 0 ? "Assistant replied after \(steps) tool \(steps == 1 ? "step" : "steps")" : "Assistant replied"
    }

    /// True when the composer text is worth sending.
    static func canSend(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
