import Foundation

/// Token accounting for one provider call, or a sum of several (AI-12). Only
/// providers that report counts populate it; nothing is estimated.
struct AIUsage: Equatable, Codable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0

    var totalTokens: Int { promptTokens + completionTokens }
    var isEmpty: Bool { promptTokens == 0 && completionTokens == 0 }

    static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(promptTokens: lhs.promptTokens + rhs.promptTokens,
                completionTokens: lhs.completionTokens + rhs.completionTokens)
    }

    static func += (lhs: inout AIUsage, rhs: AIUsage) { lhs = lhs + rhs }

    /// Short label such as "1,204 in / 88 out".
    var summary: String {
        let format = { (tokens: Int) in tokens.formatted(.number) }
        return "\(format(promptTokens)) in / \(format(completionTokens)) out"
    }
}

/// Pure snapshot-to-delta step for providers that stream cumulative snapshots
/// (Apple Intelligence). A monotonic snapshot yields only the appended suffix; a
/// revised one yields a replacement of what was already emitted, never the whole
/// snapshot appended a second time (AI-06).
enum AISnapshotDiff {
    enum Step: Equatable {
        case none
        case append(String)
        case replace(old: String, new: String)
    }

    static func step(emitted: String, snapshot: String) -> Step {
        if snapshot == emitted { return .none }
        if snapshot.hasPrefix(emitted) {
            return .append(String(snapshot.dropFirst(emitted.count)))
        }
        return .replace(old: emitted, new: snapshot)
    }
}

/// Applies a `textReplace` stream event to accumulated text: swap the trailing
/// `old` for `new`, or append `new` when the text does not end with `old`.
enum AITextReplace {
    static func apply(to text: String, old: String, new: String) -> String {
        text.hasSuffix(old) ? String(text.dropLast(old.count)) + new : text + new
    }
}
