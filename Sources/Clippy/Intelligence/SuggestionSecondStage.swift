import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// What the second stage sees: truncated previews and a context summary only.
struct SecondStageInput {
    struct Item { var id: Int64; var preview: String }
    var items: [Item]
    /// App name and window title, e.g. "Mail — Re: Lisbon trip". Never window text.
    var contextSummary: String
}

/// The second stage's verdict: clip ids best-first and optional reasons.
struct SecondStageOutput {
    var orderedIDs: [Int64]
    var reasons: [Int64: String]
}

/// Optional re-rank/explain step over the top candidates (ROADMAP INT-06).
/// Injected so tests can prove it never runs when disabled.
protocol SuggestionSecondStage: Sendable {
    /// Returns nil for "no opinion". Must honour task cancellation.
    func refine(_ input: SecondStageInput) async throws -> SecondStageOutput?
}

/// Applies a second stage to a ranked list within a hard time budget.
enum SecondStageRunner {
    /// Longest preview handed to a stage.
    static let previewChars = 120
    static let maxReasonChars = 60

    /// Re-ranks the first `SuggestionTuning.secondStageCandidates` of `ranked`.
    /// Any failure, timeout, or empty answer returns `ranked` unchanged. Blocks
    /// the calling (background) thread for at most `timeout`.
    static func apply(
        to ranked: [Suggestion], contextSummary: String, stage: SuggestionSecondStage,
        timeout: TimeInterval = SuggestionTuning.secondStageTimeout
    ) -> [Suggestion] {
        let pool = Array(ranked.prefix(SuggestionTuning.secondStageCandidates))
        let items: [SecondStageInput.Item] = pool.compactMap { suggestion in
            let clip = suggestion.clip
            guard clip.contentKind == .text, !SensitiveContent.isSensitive(text: clip.contentText)
            else { return nil }
            let flat = String(clip.contentText.prefix(previewChars * 2))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !flat.isEmpty else { return nil }
            return .init(id: suggestion.id, preview: String(flat.prefix(previewChars)))
        }
        guard items.count >= 2 else { return ranked }

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let input = SecondStageInput(items: items, contextSummary: contextSummary)
        let task = Task.detached {
            box.output = try? await stage.refine(input)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return ranked
        }
        guard let output = box.output else { return ranked }

        let allowed = Set(items.map(\.id))
        var order: [Int64] = []
        for id in output.orderedIDs where allowed.contains(id) && !order.contains(id) { order.append(id) }
        guard !order.isEmpty else { return ranked }
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var head: [Suggestion] = order.compactMap { byID[$0] }
        for index in head.indices {
            if let reason = output.reasons[head[index].id] {
                let clean = reason.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    head[index].reason = String(clean.prefix(maxReasonChars))
                    head[index].isRefined = true
                }
            }
        }
        let placed = Set(order)
        let rest = ranked.filter { !placed.contains($0.id) }
        return head + rest
    }

    private final class Box: @unchecked Sendable { var output: SecondStageOutput? }
}

#if canImport(FoundationModels)
    /// Apple Foundation Models implementation. Runs on-device only and only when
    /// `SystemLanguageModel.default.availability == .available`; the prompt
    /// holds truncated previews and the app/title summary, nothing else.
    struct FoundationModelsSecondStage: SuggestionSecondStage {
        func refine(_ input: SecondStageInput) async throws -> SecondStageOutput? {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let list = input.items.map { "[\($0.id)] \($0.preview)" }.joined(separator: "\n")
            let prompt = """
                The user is working in: \(input.contextSummary)
                Clipboard clips:
                \(list)

                List the clip ids most relevant to that context, best first, one per line \
                in the form `id: reason` (reason at most 8 words). Omit irrelevant clips.
                """
            let session = LanguageModelSession(
                instructions: "You rank clipboard history for relevance. Answer only with the requested lines.")
            let response = try await session.respond(to: prompt)
            return Self.parse(response.content, allowed: Set(input.items.map(\.id)))
        }

        /// Parses `id: reason` lines, ignoring anything else.
        static func parse(_ text: String, allowed: Set<Int64>) -> SecondStageOutput? {
            var ids: [Int64] = []
            var reasons: [Int64: String] = [:]
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]`-* \t"))
                let parts = trimmed.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]`* \t"))
                }
                guard let first = parts.first, let id = Int64(first), allowed.contains(id),
                    !ids.contains(id)
                else { continue }
                ids.append(id)
                if parts.count > 1, !parts[1].isEmpty { reasons[id] = parts[1] }
            }
            return ids.isEmpty ? nil : SecondStageOutput(orderedIDs: ids, reasons: reasons)
        }
    }
#endif
