import Foundation

/// One dismissal a user can apply to a suggestion (INT-07).
enum SuggestionFeedbackAction: Equatable {
    case notRelevant, neverSuggest, excludeApp(bundleID: String, appName: String?)

    /// Toast text after applying the action. Metadata only, never clip text.
    var toastMessage: String {
        switch self {
        case .notRelevant: return "Marked not relevant"
        case .neverSuggest: return "Won't suggest this clip again"
        case .excludeApp(_, let name): return "No suggestions from \(name ?? "this app")"
        }
    }
}

/// Applies and undoes dismissals against a `SuggestionDismissals` store.
struct SuggestionFeedback {
    let dismissals: SuggestionDismissals

    init(dismissals: SuggestionDismissals = .shared) { self.dismissals = dismissals }

    /// Records `action` for `clip`.
    func apply(_ action: SuggestionFeedbackAction, to clip: Clip, now: Date = Date()) {
        switch action {
        case .notRelevant: dismissals.markNotRelevant(clip, now: now)
        case .neverSuggest: dismissals.neverSuggest(clip)
        case .excludeApp(let bundleID, _): dismissals.excludeApp(bundleID)
        }
    }

    /// Reverses `apply`.
    func undo(_ action: SuggestionFeedbackAction, for clip: Clip) {
        switch action {
        case .notRelevant, .neverSuggest: dismissals.restore(contentKey: clip.contentKey)
        case .excludeApp(let bundleID, _): dismissals.includeApp(bundleID)
        }
    }

    /// The action for the app a clip came from, or nil when its source app is unknown.
    static func excludeAppAction(for clip: Clip) -> SuggestionFeedbackAction? {
        guard let bundle = clip.sourceAppBundleID, !bundle.isEmpty else { return nil }
        return .excludeApp(bundleID: bundle, appName: clip.sourceAppName)
    }
}

/// Owns the undo toast and removes dismissed rows from the store's list.
@MainActor
final class SuggestionFeedbackModel: ObservableObject {
    /// Message of the visible undo toast.
    @Published var toast: String?
    private var pending: (action: SuggestionFeedbackAction, clip: Clip, before: [Suggestion])?
    private var dismissTask: Task<Void, Never>?
    private let feedback: SuggestionFeedback

    init(feedback: SuggestionFeedback = SuggestionFeedback()) { self.feedback = feedback }

    /// Applies `action`, hides the row (or, for an app exclusion, all its rows) and shows the toast.
    func dismiss(_ action: SuggestionFeedbackAction, clip: Clip, store: ClipStore) {
        feedback.apply(action, to: clip)
        let before = store.suggestions
        if case .excludeApp(let bundleID, _) = action {
            store.suggestions.removeAll { $0.clip.sourceAppBundleID == bundleID }
        } else {
            store.suggestions.removeAll { $0.clip.contentKey == clip.contentKey }
        }
        pending = (action, clip, before)
        toast = action.toastMessage
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.clearToast() }
        }
    }

    /// Reverts the last dismissal and restores the list.
    func undo(store: ClipStore) {
        guard let pending else { return }
        feedback.undo(pending.action, for: pending.clip)
        store.suggestions = pending.before
        clearToast()
    }

    /// Hides the toast without undoing.
    func clearToast() {
        dismissTask?.cancel()
        toast = nil
        pending = nil
    }
}
