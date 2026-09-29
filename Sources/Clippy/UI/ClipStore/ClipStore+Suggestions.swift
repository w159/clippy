import Foundation

extension ClipStore {
    /// Newest resident clips considered for ranking.
    private static let suggestionCandidateCap = 1500

    /// Main-thread entry. Ranks resident clips against `context` on a
    /// background queue and publishes the result on main. `nil` context means
    /// nothing could be read (no permission, ignored app, or secure field).
    func refreshSuggestions(context: ScreenContext?) {
        let settings = AppSettings.shared
        suggestionsToken &+= 1
        let token = suggestionsToken
        guard settings.suggestionsEnabled else {
            setSuggestions([], state: .disabled, summary: nil)
            return
        }
        guard var context, !context.isEmpty else {
            setSuggestions([], state: CaretLocator.isTrusted ? .empty : .needsPermission, summary: nil)
            return
        }
        if !settings.suggestionsUseWindowText { context.text = "" }
        let summary = [context.appName, context.windowTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        let limit = min(20, max(3, settings.suggestionsLimit))
        let ignored = Set(settings.ignoredBundleIDs)
        let candidates = suggestionCandidates()
        suggestionsState = .loading
        suggestionsContextSummary = summary.isEmpty ? nil : summary
        let engine = SuggestionEngine.shared
        let ranking = context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            engine.ignoredBundleIDs = ignored
            let ranked = engine.rank(context: ranking, clips: candidates, limit: limit, now: Date())
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                guard let self, self.suggestionsToken == token else { return }
                ClippyLog.info(
                    "suggestions: ranked \(candidates.count) clips -> \(ranked.count) in \(elapsedMs)ms",
                    category: ClippyLog.storage)
                self.setSuggestions(
                    ranked, state: ranked.isEmpty ? .empty : .ready,
                    summary: summary.isEmpty ? nil : summary)
            }
        }
    }

    /// "Find Similar": suggestions related to one clip.
    func findSimilar(to clip: Clip) {
        let settings = AppSettings.shared
        suggestionsToken &+= 1
        let token = suggestionsToken
        guard settings.suggestionsEnabled else {
            setSuggestions([], state: .disabled, summary: nil)
            return
        }
        let preview = clip.previewText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let summary = "Similar to: " + String(preview.prefix(40))
        let limit = min(20, max(3, settings.suggestionsLimit))
        let ignored = Set(settings.ignoredBundleIDs)
        let candidates = suggestionCandidates()
        suggestionsState = .loading
        suggestionsContextSummary = summary
        let engine = SuggestionEngine.shared
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            engine.ignoredBundleIDs = ignored
            let ranked = engine.related(to: clip, clips: candidates, limit: limit, now: Date())
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                guard let self, self.suggestionsToken == token else { return }
                ClippyLog.info(
                    "similar: ranked \(candidates.count) clips -> \(ranked.count) in \(elapsedMs)ms",
                    category: ClippyLog.storage)
                self.setSuggestions(ranked, state: ranked.isEmpty ? .empty : .ready, summary: summary)
            }
        }
    }

    /// Drops suggestions and the context summary (called when the panel hides).
    func clearSuggestions() {
        suggestionsToken &+= 1
        suggestions = []
        suggestionsContextSummary = nil
        suggestionsState = AppSettings.shared.suggestionsEnabled ? .empty : .disabled
    }

    private func suggestionCandidates() -> [Clip] {
        Array(recents.lazy.filter { $0.contentKind != .text || !$0.contentText.isEmpty }
            .prefix(Self.suggestionCandidateCap))
    }

    private func setSuggestions(_ list: [Suggestion], state: SuggestionsState, summary: String?) {
        suggestions = list
        suggestionsState = state
        suggestionsContextSummary = summary
    }
}
