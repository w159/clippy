import SwiftUI

/// One tray row: a suggestion plus the display name of its category.
struct AutoFileTrayItem: Identifiable, Equatable {
    var suggestion: AutoFileSuggestion
    var categoryName: String

    var id: String { suggestion.id }
}

/// Chips offering "File under <category>". Accept and dismiss are explicit
/// user actions; the tray never files anything by itself. Suggestions come
/// from on-device embeddings only.
struct AutoFileTray: View {
    let items: [AutoFileTrayItem]
    let onAccept: (AutoFileSuggestion) -> Void
    let onDismiss: (AutoFileSuggestion) -> Void

    /// Creates a tray for `items`; the integrator supplies the action handlers.
    init(
        items: [AutoFileTrayItem], onAccept: @escaping (AutoFileSuggestion) -> Void,
        onDismiss: @escaping (AutoFileSuggestion) -> Void
    ) {
        self.items = items
        self.onAccept = onAccept
        self.onDismiss = onDismiss
    }

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in chip(item) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Category suggestions")
        }
    }

    private func chip(_ item: AutoFileTrayItem) -> some View {
        HStack(spacing: 6) {
            Button { onAccept(item.suggestion) } label: {
                Label("File under \(item.categoryName)", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help(item.suggestion.reason)
            Button { onDismiss(item.suggestion) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestion for \(item.categoryName)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
    }
}
