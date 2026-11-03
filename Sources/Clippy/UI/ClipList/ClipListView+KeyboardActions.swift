import SwiftUI

// Keyboard routes to the actions the card context menu offers: the actions key
// opens the command palette (it lists the same clip actions), and the commands
// the menu had alone (rename, plain-text copy, reveal, multi-select toggle) get
// their own keys.

extension ClipListView {
    /// Shift+F10 and the Menu key open the actions for the selected clip. The
    /// SwiftUI context menu cannot be popped from code, so the Cmd+K palette,
    /// which carries every clip action, stands in for it.
    func handleActionsKey(_ press: KeyPress) -> KeyPress.Result? {
        let menuKey = press.characters == "\u{F735}"
        let shiftF10 = press.characters == "\u{F70D}" && press.modifiers.contains(.shift)
        guard menuKey || shiftF10 else { return nil }
        guard selectedClip != nil else { return .ignored }
        paletteVisible = true
        return .handled
    }

    /// Cmd+Return: toggles the cursor row in or out of the multi-selection,
    /// as Cmd-click does, without moving the cursor.
    func toggleCursorSelection() {
        guard let id = selectedClip?.id else { return }
        selectionFollowsTop = false
        syncRangeModel()
        rangeModel.toggle(id)
        selectedClipIDs = rangeModel.published
    }

    /// Cmd+R: starts the inline rename of the single targeted clip.
    func beginRenameSelected() -> Bool {
        guard let clip = singleActionClip else { return false }
        renamingClipID = clip.id
        return true
    }

    /// Cmd+Shift+R: shows or hides the targeted sensitive clip, the keyboard
    /// twin of holding the reveal gesture. False when nothing sensitive is targeted.
    func toggleKeyReveal() -> Bool {
        guard let clip = singleActionClip, CardSensitivity.isSensitive(clip) else { return false }
        revealedClipID = revealedClipID == clip.id ? nil : clip.id
        return true
    }

    /// Tab walks sidebar, search field, list; Shift+Tab walks back. The panes
    /// are plain focusable views, so AppKit's key loop does not link them.
    func moveFocusRing(from source: PanelFocusTarget, backward: Bool) -> KeyPress.Result {
        let hasSearch = SearchFieldPolicy.showsSearchField(for: selection)
        switch (source, backward) {
        case (.search, false):
            if visibleClips.isEmpty { PanelFocusRequest.shared.requestSidebar() } else { focusTarget = .list }
        case (.list, false), (.search, true):
            PanelFocusRequest.shared.requestSidebar()
        case (.list, true):
            if hasSearch { focusTarget = .search } else { PanelFocusRequest.shared.requestSidebar() }
        }
        return .handled
    }

    /// Files the targeted clips into `categoryID` (palette "Move to ...").
    func moveActionableClips(toCategory categoryID: Int64) {
        for clip in actionableClips {
            if let id = clip.id { store.fileClip(id: id, intoCategory: categoryID) }
        }
    }
}
