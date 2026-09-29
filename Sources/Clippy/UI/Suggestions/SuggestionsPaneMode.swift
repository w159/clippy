import Foundation

/// What the Suggestions pane shows, derived from store state and diagnostics.
enum SuggestionsPaneMode: Equatable {
    case list, loading, needsPermission, disabled, empty
    /// The frontmost app is being skipped after repeated slow reads (INT-08).
    case skipped(message: String)

    /// Chooses the mode. A skipped host explains an otherwise empty pane.
    static func resolve(
        state: SuggestionsState, hasSuggestions: Bool, diagnostics: SuggestionDiagnostics
    ) -> SuggestionsPaneMode {
        switch state {
        case .disabled: return .disabled
        case .needsPermission: return .needsPermission
        case .loading: return .loading
        case .ready where hasSuggestions: return .list
        case .ready, .empty:
            if let message = diagnostics.skipMessage { return .skipped(message: message) }
            return .empty
        }
    }
}

extension Suggestion {
    /// Chip text: the reason, or an Apple Intelligence attribution when the second stage wrote it.
    var chipTitle: String { reason }

    /// Explanation shown on hover.
    var chipExplanation: String {
        isRefined ? "Refined with Apple Intelligence on this Mac: \(reason)" : "Why this was suggested: \(reason)"
    }

    /// Whole-percent relevance for the score bar label.
    var scorePercent: Int { Int((min(max(score, 0), 1) * 100).rounded()) }
}

extension ClipStore {
    /// Re-reads the frontmost app's context off-main and re-ranks (header refresh button).
    func recaptureSuggestions() {
        let settings = AppSettings.shared
        guard settings.suggestionsEnabled else { return }
        let ignored = Set(settings.ignoredBundleIDs)
        let maxChars = settings.suggestionsUseWindowText ? 1500 : 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let context = ContextReader.capture(ignoredBundleIDs: ignored, maxChars: maxChars)
            DispatchQueue.main.async { self?.refreshSuggestions(context: context) }
        }
    }
}
