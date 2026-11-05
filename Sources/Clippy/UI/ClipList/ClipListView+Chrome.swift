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
        } else if HistoryPanePolicy.isSearching(store.query) {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "No clips match",
                message: "Remove a filter chip, check spelling, or search a shorter phrase.",
                actionTitle: "Clear Search"
            ) { store.query = "" }
        } else {
            switch selection {
            case .history:
                EmptyState(systemImage: "clipboard", title: "No clips yet",
                           message: "Copy something and it will show up here.")
            case .category:
                EmptyState(systemImage: "tray", title: "No clips in this category",
                           message: "Right-click a clip and choose Categories, or drag a card onto the category.")
            // These routes render their own panes in `paneContent`; the copy is a safety net.
            case .onePassword, .scripts, .assistant, .aiActions, .suggestions, .snippets, .pasteStack:
                EmptyState(systemImage: "tray", title: routeFallbackTitle)
            }
        }
    }

    /// One-line copy per route that normally draws its own pane.
    private var routeFallbackTitle: String {
        switch selection {
        case .onePassword: return "No 1Password items to show"
        case .scripts: return "No scripts to show"
        case .assistant: return "Assistant is not available here"
        case .aiActions: return "No AI actions to show"
        case .suggestions: return "No suggestions to show"
        case .snippets: return "No snippets to show"
        case .pasteStack: return "Paste stack is empty"
        case .history, .category: return "No clips to show"
        }
    }

    // MARK: - Batch action bar

    /// Shown above the footer when 2+ clips are selected. Operates on
    /// `actionableClips` so it tracks the live multi-selection. Labels are
    /// spelled out in Title Case (no "Seq." abbreviations); Delete sits last,
    /// after a divider, and reads in the danger color.
    var batchActionBar: some View {
        let space = designTokens.metrics.space
        return HStack(spacing: space.three) {
            batchButton("Paste in Order", "list.number",
                        help: "Paste the selected clips one after another") {
                onPasteMany(actionableClips, false, settings.pastePlainTextByDefault)
            }
            batchButton("Paste as One", "rectangle.compress.vertical",
                        help: "Join the selected clips and paste them as a single clip") {
                onPasteMany(actionableClips, true, settings.pastePlainTextByDefault)
            }
            if settings.aiEnabled {
                batchButton("Generate Titles", "sparkles", help: "Name each selected clip with AI") { runBatchAITitles() }
            }
            batchButton("Delete", "trash", help: "Delete the selected clips", role: .destructive) { requestBatchDelete() }
            Spacer()
        }
        .padding(.horizontal, space.four).padding(.vertical, space.two)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, space.three).padding(.bottom, space.one)
    }

    func batchButton(_ label: String, _ symbol: String, help: String, role: ButtonRole? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(label, systemImage: symbol).font(.callout)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? designTokens.danger : designTokens.textPrimary)
        .help(help)
    }

    var footer: some View {
        let space = designTokens.metrics.space
        return GlassEffectContainer(spacing: space.two) {
            HStack(spacing: space.two) {
                if selectedClipIDs.count >= 2 {
                    Text("\(selectedClipIDs.count) selected")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, space.three).padding(.vertical, space.one + 1)
                        .foregroundStyle(designTokens.onAccent)
                        .glassEffect(.regular.tint(designTokens.accent), in: Capsule())
                }
                ForEach(PanelDisclosure.footerHints(selectedCount: selectedClipIDs.count, hasClips: !visibleClips.isEmpty,
                                                    plainByDefault: settings.pastePlainTextByDefault,
                                                    isPinnedPanel: settings.panelPinned, width: listWidth), id: \.key) { hint in
                    keyHint(hint.key, hint.label)
                }
                Spacer()
            }
        }
        .padding(.horizontal, space.four)
        .frame(height: PanelLayout.footerHeight)
    }

    /// One footer hint: a small glass capsule holding the key and its action.
    func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: designTokens.metrics.space.one + 2) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, designTokens.metrics.space.three)
        .padding(.vertical, designTokens.metrics.space.one + 1)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }
}
