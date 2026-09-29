import SwiftUI
import AppKit

// Suggestions pane wiring for `ClipListView` (selection == .suggestions).

extension ClipListView {
    /// Smart Suggestions pane: hero header, then either a state view or the
    /// ranked clips as cards wrapped in reason chips, keycaps 1-9 and a row menu.
    var suggestionsPane: some View {
        SuggestionsPaneHost(store: store, onOpenSettings: onOpenSettings) { feedback in
            suggestionsList(feedback: feedback)
        }
    }

    private func suggestionsList(feedback: SuggestionFeedbackModel) -> some View {
        let suggestions = store.suggestions
        let metadata = cardMetadata(for: suggestions.map(\.clip))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRowChrome(
                            suggestion: suggestion, index: index,
                            card: card(for: suggestion.clip, at: index, metadata: metadata),
                            onPaste: { plain in onPaste(suggestion.clip, plain) },
                            onFeedback: { feedback.dismiss($0, clip: suggestion.clip, store: store) },
                            onFindSimilar: { store.findSimilar(to: suggestion.clip) })
                    }
                }
                .padding(10)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focusTarget, equals: .list)
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, from: .list) }
            .onChange(of: selectedIndex) { _, newIndex in
                guard suggestions.indices.contains(newIndex) else { return }
                proxy.scrollTo(suggestions[newIndex].clip.id, anchor: nil)
            }
        }
    }
}
