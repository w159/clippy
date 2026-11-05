import SwiftUI
import AppKit

// Shell composition for `ClipListView`: header, sidebar split, command
// palette wiring and the status/notification hooks, kept out of the main file.

extension ClipListView {
    /// Section title shown in the header.
    var sectionTitle: String {
        switch selection {
        case .history: return "History"
        case .category(let id): return store.categories.first { $0.id == id }?.name ?? "Category"
        case .onePassword: return "1Password"
        case .scripts: return "Scripts"
        case .assistant: return "Assistant"
        case .aiActions: return "AI Actions"
        case .suggestions: return "Suggestions"
        case .snippets: return "Snippets"
        case .pasteStack: return "Paste Stack"
        }
    }

    /// Single top row with drag region, section title, count, the search field (panes
    /// that search) and quick toggles.
    @ViewBuilder
    var panelHeader: some View {
        if SearchFieldPolicy.showsSearchField(for: selection) {
            PanelHeaderView(
                sectionTitle: sectionTitle,
                clipCount: visibleClips.count,
                isPinned: settings.panelPinned,
                onTogglePin: { settings.panelPinned.toggle() },
                onToggleSidebar: { NotificationCenter.default.post(name: .clippyToggleSidebar, object: nil) },
                onOpenSettings: onOpenSettings,
                onClose: onClose,
                search: { headerSearchField }
            )
            .background(tokens.headerBar.opacity(settings.panelOpacity))
        } else {
            PanelHeaderView(
                sectionTitle: sectionTitle,
                clipCount: nil,
                isPinned: settings.panelPinned,
                onTogglePin: { settings.panelPinned.toggle() },
                onToggleSidebar: { NotificationCenter.default.post(name: .clippyToggleSidebar, object: nil) },
                onOpenSettings: onOpenSettings,
                onClose: onClose
            )
            .background(tokens.headerBar.opacity(settings.panelOpacity))
        }
    }

    /// Persistent banners for search and observation failures, each with Try Again.
    /// Hidden when the clip list is empty: `emptyState` then shows the same error
    /// as a full ErrorState, and showing both stacked the message twice.
    @ViewBuilder
    var errorBanners: some View {
        if !(visibleClips.isEmpty && showsClipList) {
            if let message = store.searchError {
                ClippyBanner(message, severity: .danger, actionTitle: "Try Again", action: { store.retrySearch() })
                    .padding(.horizontal, designTokens.metrics.space.three).padding(.vertical, designTokens.metrics.space.one)
            }
            if let message = store.observationError {
                ClippyBanner(message, severity: .danger, actionTitle: "Try Again", action: { store.retryObservation() })
                    .padding(.horizontal, designTokens.metrics.space.three).padding(.vertical, designTokens.metrics.space.one)
            }
        }
    }

    /// True when the main pane is the clip grid or list (so `emptyState` can appear),
    /// not one of the panes that route to their own view in `paneContent`.
    var showsClipList: Bool {
        switch selection {
        case .scripts, .onePassword, .assistant, .aiActions, .suggestions, .snippets, .pasteStack: return false
        default: return true
        }
    }

    /// Sidebar and main pane in the resizable, collapsible split.
    var splitContent: some View {
        SidebarSplitView(
            minContentWidth: GridMetrics.minCardWidth + GridMetrics.listPadding * 2 + GridMetrics.spacing,
            reservedTrailingWidth: showsPreviewColumn ? PreviewColumnPreferences.width() : 0,
            sidebar: { isRail in
                CategorySidePane(store: store, selection: $selection, isRail: isRail, smartCollections: smartCollections)
            },
            content: { mainWithFeatures }
        )
    }

    /// Command palette overlay, shown by Cmd+K.
    @ViewBuilder
    var paletteOverlay: some View {
        if paletteVisible {
            CommandPaletteHost(commands: BuiltInCommands.all(commandContext), onDismiss: closePalette)
        }
    }

    /// Hidden Cmd+K trigger.
    var paletteShortcut: some View {
        Button("Command Palette") { togglePalette() }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// Runs the `clippy://` request waiting for the panel, if any.
    func applyLaunchRequest() {
        guard let action = PanelLaunchRequest.shared.take() else { return }
        switch action {
        case .search(let query):
            selection = .history
            store.query = query
            focusTarget = .search
            searchSelection = TextSelection(insertionPoint: query.endIndex)
        case .reveal(let id):
            if let clip = store.recentsByID[id] {
                revealInTimeline(clip)
            } else {
                // Not in the loaded window: attemptPendingReveal reports that.
                pendingRevealClipID = id
                selection = .history
                store.query = ""
                Task { @MainActor in attemptPendingReveal() }
            }
        case .palette:
            paletteVisible = true
        }
    }

    /// Cmd+K: opens the palette; a second press closes it through `closePalette`
    /// so focus returns instead of being left on nothing.
    func togglePalette() {
        let next = PaletteTogglePolicy.next(isVisible: paletteVisible)
        if next.visible { paletteVisible = true } else { closePalette() }
    }

    /// Closes the palette and returns focus to the search field.
    func closePalette() {
        paletteVisible = false
        focusTarget = .search
    }

    /// Closures the built-in commands run, bound to the current selection.
    var commandContext: PanelCommandContext {
        let clip = selectedClip
        let grid = GridPreferences.shared
        return PanelCommandContext(
            hasSelectedClip: clip != nil,
            hasQuery: !store.query.isEmpty,
            canExtractText: clip?.contentKind == .image,
            canFindSimilar: settings.suggestionsEnabled && clip?.contentKind == .text,
            isPinned: clip.map { store.isPinned($0) } ?? false,
            paste: { if let clip { onPaste(clip, settings.pastePlainTextByDefault) } },
            pastePlain: { if let clip { onPaste(clip, true) } },
            togglePin: { if let clip { store.togglePin(clip) } },
            // Matches Cmd+Delete: a multi-selection deletes every selected clip, not just the anchor.
            deleteSelection: {
                let targets = actionableClips
                if targets.count >= 2 { requestBatchDelete() } else if let target = targets.first { requestDelete(target) }
            },
            findSimilar: { if let clip { showSimilarClips(to: clip) } },
            openSettings: onOpenSettings,
            toggleSidebar: { NotificationCenter.default.post(name: .clippyToggleSidebar, object: nil) },
            currentDensity: grid.density,
            setDensity: { grid.density = $0 },
            suggestionsEnabled: settings.suggestionsEnabled,
            toggleSuggestions: { settings.suggestionsEnabled.toggle() },
            clearSearch: { store.query = "" },
            extractText: { if let clip { runOCR(on: clip) } },
            newCategory: { categoryCreationClip = clip },
            featureCommands: featurePaletteCommands,
            selectionCount: max(selectedClipIDs.count, 1),
            rename: { _ = beginRenameSelected() },
            copyPlain: { copyActionableClips(plainText: true) },
            toggleReveal: { _ = toggleKeyReveal() },
            canReveal: singleActionClip.map(CardSensitivity.isSensitive) ?? false,
            moveTargets: store.categories.compactMap { category in category.id.map { (id: $0, name: category.name) } },
            moveToCategory: { moveActionableClips(toCategory: $0) }
        )
    }
}
