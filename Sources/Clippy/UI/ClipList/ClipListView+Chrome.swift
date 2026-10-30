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
            batchButton("Generate Titles", "sparkles", help: "Name each selected clip with AI") { runBatchAITitles() }
            Divider().frame(height: 14)
            batchButton("Delete", "trash", help: "Delete the selected clips", role: .destructive) { requestBatchDelete() }
            Spacer()
        }
        .padding(.horizontal, space.three).padding(.vertical, space.two)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    func batchButton(_ label: String, _ symbol: String, help: String, role: ButtonRole? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(label, systemImage: symbol).font(PanelTypography.metadata(settings))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? designTokens.danger : designTokens.textPrimary)
        .help(help)
    }

    var footer: some View {
        let space = designTokens.metrics.space
        return HStack(spacing: space.three) {
            if selectedClipIDs.count >= 2 {
                Text("\(selectedClipIDs.count) selected")
                    .font(PanelTypography.micro(settings))
                    .padding(.horizontal, space.two).padding(.vertical, 2)
                    .background(designTokens.selection, in: Capsule())
                    .foregroundStyle(designTokens.accentText)
            }
            ForEach(PanelDisclosure.footerHints(selectedCount: selectedClipIDs.count, hasClips: !visibleClips.isEmpty,
                                                plainByDefault: settings.pastePlainTextByDefault,
                                                isPinnedPanel: settings.panelPinned, width: listWidth), id: \.key) { hint in
                keyHint(hint.key, hint.label)
            }
            Spacer()
        }
        .padding(.horizontal, space.three)
        .padding(.vertical, space.two)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    /// One footer hint: a key cap (shared `KeyCap` component, so the footer and
    /// the command palette draw keys the same way) and its action in secondary text.
    func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: designTokens.metrics.space.one) {
            KeyCap(key)
            Text(action)
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(designTokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }
}
