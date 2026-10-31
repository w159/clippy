import SwiftUI
import AppKit

// Selection model for `ClipListView`: actionable clips, keyboard and range
// selection, row-click handling, paste, and timeline reveal.

extension ClipListView {
    /// The clips batch actions operate on: the explicit multi-selection if any,
    /// otherwise the single keyboard-anchored clip.
    var actionableClips: [Clip] {
        let clips = visibleClips
        let ids = ActionTargetPolicy.ids(selected: selectedClipIDs, cursorID: selectedClip?.id,
                                         order: clips.compactMap(\.id))
        return clips.filter { clip in clip.id.map(ids.contains) ?? false }
    }

    /// The one clip a single-clip action (Return, Cmd+P, Cmd+E, delete) targets:
    /// what is highlighted, which after a Cmd-click deselect is not the cursor row.
    var singleActionClip: Clip? {
        let clips = actionableClips
        return clips.count == 1 ? clips[0] : nil
    }

    // MARK: - Timeline reveal

    /// "Show in Timeline": jump from a search result (or any pane) to the
    /// clip's chronological home. Unpinned clips live in History under their
    /// date bucket; pinned clips never appear in History, so they reveal in
    /// their first category pane instead. Clearing the query refilters the
    /// store synchronously; the pane switch lands on the next view update, so
    /// the actual select-and-scroll is deferred to attemptPendingReveal.
    func revealInTimeline(_ clip: Clip) {
        pendingRevealClipID = clip.id
        // The query clear below must not reset the cursor to row 0 afterwards.
        revealQueryGuard.arm(currentQuery: store.query)
        store.query = ""
        if store.isPinned(clip), let categoryID = store.firstCategory(for: clip)?.id {
            selection = .category(categoryID)
        } else {
            selection = .history
        }
        // Same-pane reveal (e.g. searching within History): neither store.clips
        // nor selection changes, so neither onChange fires. Defer one turn so
        // the query-clear refilter has applied, then resolve directly.
        Task { @MainActor in
            attemptPendingReveal()
        }
    }

    /// Completes a pending reveal once the target clip is present in the
    /// visible pane: selects it, anchors it (so DB pulses keep it in place),
    /// and lets the selectedIndex onChange scroll it into view. A clip that is
    /// no longer visible (older than the history window) surfaces a banner
    /// instead of failing silently.
    func attemptPendingReveal() {
        guard let target = pendingRevealClipID else { return }
        if let index = visibleClips.firstIndex(where: { $0.id == target }) {
            pendingRevealClipID = nil
            selectedClipIDs = []
            selectionFollowsTop = false
            anchoredClipID = target
            selectedIndex = index
        } else if store.query.isEmpty {
            // Query already cleared and the pane still lacks the clip: it fell
            // out of the visible history window. Stop waiting and say so.
            pendingRevealClipID = nil
            showStatusBanner("Clip is older than the \(Self.displayLimit) most recent shown in History")
        }
    }

    // MARK: - Change handlers (kept out of `body` to keep it type-checkable)

    /// The visible list republished (DB pulse, delete, filing, new suggestions):
    /// keep the cursor on its clip, or on the neighbour row when the clip is gone.
    func handleClipsChanged() {
        let clips = visibleClips
        let newIDs = Set(clips.compactMap { $0.id })
        selectedClipIDs.formIntersection(newIDs)
        rangeModel.prune(keeping: newIDs)
        selectedIndex = ResultSelectionPolicy.index(in: clips, anchor: anchoredClipID,
                                                    followsTop: selectionFollowsTop, previousIndex: selectedIndex)
        anchoredClipID = clips.indices.contains(selectedIndex) ? clips[selectedIndex].id : nil
        attemptPendingReveal()
    }

    func handleQueryChanged() {
        // A reveal clears the query to find its clip; that must not undo the reveal.
        if revealQueryGuard.consumeQueryChange() { pendingReturnShift = nil; return }
        // Suggestions cannot be searched; a typed query searches History.
        if SuggestionsQueryPolicy.redirectsToHistory(selection: selection, query: store.query) { selection = .history }
        selectionFollowsTop = true
        pendingReturnShift = nil
        syncRangeModel()
        rangeModel.collapseToCursor()
        selectedClipIDs = []
        selectedIndex = 0
    }

    func handleSelectionChanged(from oldValue: PanelSelection, to newValue: PanelSelection) {
        let previousFocus = focusTarget
        if isAutoOpeningSuggestions {
            isAutoOpeningSuggestions = false
        } else {
            userChangedSelection = true
        }
        // Opening the assistant carries the anchored text clip in as the
        // context chip. Resolve against the OUTGOING pane's clips because
        // `selection` (and thus visibleClips) has already switched. An
        // explicit "Open AI Assistant" set the clip itself; do not clobber it.
        if newValue == .assistant {
            if assistantContextExplicit {
                assistantContextExplicit = false
            } else {
                let outgoing = clips(for: oldValue)
                if outgoing.indices.contains(selectedIndex),
                   outgoing[selectedIndex].contentKind == .text {
                    assistantContextClip = outgoing[selectedIndex]
                }
            }
        }
        selectedIndex = 0
        selectedClipIDs = []
        // Re-anchor on the new pane's top row; the old pane's anchor is stale here.
        anchoredClipID = visibleClips.first?.id
        attemptPendingReveal()
        if let target = PanelFocusPolicy.afterPaneChange(
            previous: previousFocus, showsSearchField: SearchFieldPolicy.showsSearchField(for: newValue),
            hasClips: !visibleClips.isEmpty), !(target == .search && previousFocus == .search) {
            refocus(target)
        }
    }

    /// Re-applies focus after the focused view was replaced: the binding may
    /// already hold the value, so clear it first and set it on the next turn.
    func refocus(_ target: PanelFocusTarget) {
        focusTarget = nil
        Task { @MainActor in focusTarget = target }
    }

    /// Find Similar: show the new suggestions from their top row. Switching panes
    /// resets the cursor; from the Suggestions pane itself nothing else would.
    func showSimilarClips(to clip: Clip) {
        store.findSimilar(to: clip)
        selectedClipIDs = []
        selectedIndex = 0
        anchoredClipID = nil
        selection = .suggestions
    }

    // MARK: - Selection and actions

    var selectedClip: Clip? {
        visibleClips.indices.contains(selectedIndex) ? visibleClips[selectedIndex] : nil
    }

    /// Single-click selection with macOS modifier semantics, via the anchor+cursor
    /// range model (KEY-04):
    /// - Cmd: toggle this clip in/out of the multi-selection.
    /// - Shift: extend (or shrink) the range from the anchor to here.
    /// - Plain: collapse the selection onto this clip.
    /// `selectedIndex` follows the clicked row so Return-to-paste stays in sync.
    /// Focus moves to the list container, not back to search (KEY-06).
    func handleRowClick(_ clip: Clip, at index: Int, modifiers: EventModifiers) {
        guard let id = clip.id else { return }
        selectionFollowsTop = false
        syncRangeModel()
        if modifiers.contains(.command) {
            rangeModel.toggle(id)
        } else if modifiers.contains(.shift) {
            rangeModel.extend(to: id, order: visibleClips.compactMap(\.id))
        } else {
            rangeModel.reset(to: id)
        }
        selectedClipIDs = rangeModel.published
        selectedIndex = index
        navColumn = nil
        focusTarget = .list
    }

    func pasteSelected(shiftHeld: Bool) {
        // Multi-selection routes Return to the sequential batch paste so the
        // whole selection is honored, not just the anchored clip (audit: Return
        // pastes only the anchored clip even with multi-selection).
        let clips = actionableClips
        if clips.count >= 2 {
            guard !clips.isEmpty else { return }
            let asPlainText = settings.pastePlainTextByDefault != shiftHeld
            onPasteMany(clips, false, asPlainText)
            return
        }
        guard let clip = singleActionClip else { return }
        if shiftHeld {
            // Shift+Return always inverts the default paste mode (explicit paste).
            let asPlainText = settings.pastePlainTextByDefault != shiftHeld
            onPaste(clip, asPlainText)
        } else {
            // Plain Return follows the primary action (respects copy-only toggle).
            onPrimary(clip)
        }
    }
}
