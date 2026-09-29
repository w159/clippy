import SwiftUI
import AppKit

// Static chrome for `ClipListView`: empty state, batch action bar, footer
// and key hints.

extension ClipListView {
    // MARK: - Empty and footer

    /// Empty, no-results and error states for the current pane, all built on
    /// the design-system state views. Every state offers a way forward.
    @ViewBuilder
    var emptyState: some View {
        if let message = store.searchError {
            ErrorState(title: "Search failed", message: message) { store.retrySearch() }
        } else if let message = store.observationError {
            ErrorState(title: "History unavailable", message: message) { store.retryObservation() }
        } else if !store.query.isEmpty {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "No clips match",
                message: "Remove a filter chip, check spelling, or search a shorter phrase.",
                actionTitle: "Clear search"
            ) { store.query = "" }
        } else {
            switch selection {
            case .history:
                EmptyState(systemImage: "clipboard", title: "No clips yet",
                           message: "Copy something and it will show up here.")
            case .category:
                EmptyState(systemImage: "tray", title: "No clips in this category",
                           message: "Right-click a clip and choose Categories, or drag a card onto the category.")
            case .onePassword:
                EmptyState(systemImage: "key.fill", title: "No secrets shared to Clippy yet")
            // .scripts, .assistant, and .aiActions route to their own views; unreachable here.
            case .scripts, .assistant, .aiActions, .suggestions, .snippets, .pasteStack:
                EmptyState(systemImage: "tray", title: "Nothing to show")
            }
        }
    }

    // MARK: - Batch action bar

    /// Shown above the footer when 2+ clips are selected. Operates on
    /// `actionableClips` so it tracks the live multi-selection.
    var batchActionBar: some View {
        HStack(spacing: 10) {
            batchButton("Paste Seq.", "list.number") {
                onPasteMany(actionableClips, false, settings.pastePlainTextByDefault)
            }
            batchButton("Paste Joined", "rectangle.compress.vertical") {
                onPasteMany(actionableClips, true, settings.pastePlainTextByDefault)
            }
            batchButton("Delete", "trash") { requestBatchDelete() }
            batchButton("AI Titles", "sparkles") { runBatchAITitles() }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    func batchButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(PanelTypography.metadata(settings))
        }
        .buttonStyle(.plain)
    }

    var footer: some View {
        HStack(spacing: 14) {
            if selectedClipIDs.count >= 2 {
                Text("\(selectedClipIDs.count) selected")
                    .font(PanelTypography.micro(settings))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(tokens.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(tokens.accent)
            }
            ForEach(PanelDisclosure.footerHints(selectedCount: selectedClipIDs.count, hasClips: !visibleClips.isEmpty,
                                                plainByDefault: settings.pastePlainTextByDefault,
                                                isPinnedPanel: settings.panelPinned, width: listWidth), id: \.key) { hint in
                keyHint(hint.key, hint.label)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                // Use an explicit system font so key glyphs always render at the
                // correct weight, regardless of any custom font family chosen in
                // user appearance settings.
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(tokens.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tokens.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textPrimary.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }
}
