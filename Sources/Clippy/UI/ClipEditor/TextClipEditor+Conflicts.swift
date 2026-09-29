import AppKit
import SwiftUI

// External-change conflict handling (EDT-02).
extension TextClipEditor {
    // MARK: Conflicts (EDT-02)

    /// Reacts to the observed row changing: an MCP write, an external-editor
    /// sync, or our own save.
    func handleStored(_ stored: Clip?) {
        guard let stored else {
            clipDeleted = true
            return
        }
        clipDeleted = false
        let storedTitle = stored.userTitle ?? ""
        if storedTitle != baseTitle {
            // Adopt a renamed title unless the user is editing it.
            if title == baseTitle { title = storedTitle }
            baseTitle = storedTitle
        }
        dirtyBridge?.onTitleChange(stored.displayTitle)
        switch EditorConflictDetector.evaluate(base: baseText, mine: text, stored: stored.contentText) {
        case .unchanged:
            if conflictText != nil, conflictText != stored.contentText { conflictText = stored.contentText }
        case .adoptBase:
            baseText = stored.contentText
            conflictText = nil
        case .reload:
            adoptStored(stored.contentText)
        case .conflict:
            conflictText = stored.contentText
        }
    }

    func reloadFromConflict() {
        guard let stored = conflictText else { return }
        adoptStored(stored)
    }

    /// Replaces the edits with the stored text. In rich mode the rich value and
    /// its base move together, so the reload does not read as a formatting edit.
    private func adoptStored(_ stored: String) {
        text = stored
        baseText = stored
        conflictText = nil
        if richMode {
            let value = AttributedString(stored)
            richText = value
            baseRich = value
            richEdited = false
        }
    }

    /// Recovery for a deleted clip: the edited text goes to the pasteboard.
    func copyEditedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showStatus("Copied your text")
    }

    /// Keeps the editor's text; the stored version becomes the base so Save
    /// deliberately overwrites it.
    func keepMine() {
        if let stored = conflictText { baseText = stored }
        conflictText = nil
    }
}
