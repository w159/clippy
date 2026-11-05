import SwiftUI

/// Scaffold of the Suggestions pane: hero header, then either the state view for
/// the current `SuggestionsPaneMode` or the caller's ranked list, with an undo toast.
struct SuggestionsPaneScaffold<Content: View>: View {
    @Environment(\.clippyTokens) private var tokens
    var store: ClipStore
    var feedback: SuggestionFeedbackModel
    let onOpenSettings: () -> Void
    let content: Content

    private var mode: SuggestionsPaneMode {
        SuggestionsPaneMode.resolve(
            state: store.suggestionsState, hasSuggestions: !store.suggestions.isEmpty, diagnostics: .current())
    }

    var body: some View {
        VStack(spacing: 0) {
            SuggestionsHeroHeader(contextSummary: store.suggestionsContextSummary) { store.recaptureSuggestions() }
            ZStack(alignment: .bottom) {
                if mode == .list { content } else { stateView }
                if let message = feedback.toast {
                    ClippyToast(message, actionTitle: "Undo", action: { feedback.undo(store: store) }, dismiss: { feedback.clearToast() })
                        .padding(tokens.metrics.space.three)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch mode {
        case .needsPermission:
            PaneEmptyState(
                systemImage: "hand.raised", title: "Enable context",
                message: "Clippy needs Accessibility access to read what you are working on. Everything stays on this Mac.",
                actionTitle: "Grant Access") {
                    if !CaretLocator.requestPermission(),
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
        case .loading:
            LoadingState("Finding relevant clips", rows: 3)
        case .disabled:
            PaneEmptyState(
                systemImage: "sparkles", title: "Smart Suggestions are off",
                message: "Turn them on in Settings, Intelligence.", actionTitle: "Open Settings", action: onOpenSettings)
        case .skipped(let message):
            PaneEmptyState(systemImage: "tortoise", title: "Context unavailable in this app", message: message,
                       actionTitle: "Try Again") { store.recaptureSuggestions() }
        case .empty, .list:
            PaneEmptyState(
                systemImage: "tray", title: "Nothing relevant yet",
                message: "Copy a few things and try again.",
                actionTitle: "Refresh") { store.recaptureSuggestions() }
        }
    }

    init(
        store: ClipStore, feedback: SuggestionFeedbackModel, onOpenSettings: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.store = store
        self.feedback = feedback
        self.onOpenSettings = onOpenSettings
        self.content = content()
    }
}

/// Owns the feedback model so the extension-built pane keeps toast state across redraws.
struct SuggestionsPaneHost<Content: View>: View {
    var store: ClipStore
    @State private var feedback = SuggestionFeedbackModel()
    let onOpenSettings: () -> Void
    let content: (SuggestionFeedbackModel) -> Content

    var body: some View {
        SuggestionsPaneScaffold(store: store, feedback: feedback, onOpenSettings: onOpenSettings) { content(feedback) }
    }
}
