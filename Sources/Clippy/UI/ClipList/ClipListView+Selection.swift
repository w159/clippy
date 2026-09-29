import SwiftUI
import AppKit

// Selection model for `ClipListView`: actionable clips, keyboard and range
// selection, row-click handling, paste, and timeline reveal.

extension ClipListView {
    /// The clips batch actions operate on: the explicit multi-selection if any,
    /// otherwise the single keyboard-anchored clip.
    var actionableClips: [Clip] {
        if selectedClipIDs.isEmpty {
            return selectedClip.map { [$0] } ?? []
        }
        return visibleClips.filter { clip in clip.id.map { selectedClipIDs.contains($0) } ?? false }
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
            anchoredClipID = target
            selectedIndex = index
        } else if store.query.isEmpty {
            // Query already cleared and the pane still lacks the clip: it fell
            // out of the visible history window. Stop waiting and say so.
            pendingRevealClipID = nil
            showStatusBanner("Clip is older than the \(Self.displayLimit) most recent shown in History")
        }
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
        if selectedClipIDs.count >= 2 {
            let clips = actionableClips
            guard !clips.isEmpty else { return }
            let asPlainText = settings.pastePlainTextByDefault != shiftHeld
            onPasteMany(clips, false, asPlainText)
            return
        }
        guard let clip = selectedClip else { return }
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
