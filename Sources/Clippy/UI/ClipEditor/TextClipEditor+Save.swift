import AppKit
import SwiftUI

// Dirty tracking, drafts, save (EDT-07) and footer stats.
extension TextClipEditor {
    // MARK: Save (EDT-07)

    /// Unsaved edits exist: text or title differs from what the editor was
    /// based on, or staged AI effects wait for Save.
    var isDirty: Bool {
        text != baseText || richFormattingChanged || title != baseTitle || !pendingEffects.isEmpty
    }

    /// Formatting differs from what the rich editor opened with, even when the plain text is identical.
    var richFormattingChanged: Bool { richMode && richEdited }

    /// Draft for quit/crash recovery; nil when nothing is unsaved.
    var currentDraft: EditorDraft? {
        guard let id = clip.id, text != baseText || title != baseTitle else { return nil }  // drafts hold plain text only
        return EditorDraft(clipID: id, text: text, title: title, baseText: baseText, savedAt: Date())
    }

    /// Persist the edits. Text and title are written in one transaction; only
    /// changed fields are written. Returns true when everything landed so
    /// callers (Save button, Cmd-S, window close prompt) know whether to close;
    /// on failure the error shows inline and the window stays open.
    func save() -> Bool {
        guard let id = clip.id else {
            saveError = "This clip cannot be saved."
            return false
        }
        if conflictText != nil {
            saveError = "Resolve the conflict first: Reload or Keep mine."
            return false
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let textChanged = text != baseText
        let titleChanged = trimmedTitle != baseTitle
        let richChanged = richFormattingChanged
        if textChanged || titleChanged || richChanged {
            do {
                if richMode, textChanged || richChanged {
                    // Rich edits write contentRTF back; plain-mode saves clear it.
                    guard let rtf = RichTextConverter.rtfData(from: RichTextConverter.appKitValue(from: richText)) else {
                        saveError = "Could not save the formatting."
                        return false
                    }
                    try persistence.saveRich(id: id, text: text, rtf: rtf, title: titleChanged ? title : nil)
                } else {
                    try persistence.save(id: id, text: textChanged ? text : nil, title: titleChanged ? title : nil)
                }
            } catch {
                ClippyLog.error("editor save failed: \(error)", category: ClippyLog.storage)
                saveError = "Could not save your changes."
                return false
            }
            baseText = text
            baseRich = richText
            richEdited = false
            baseTitle = trimmedTitle
            title = trimmedTitle
            dirtyBridge?.onTitleChange(trimmedTitle.isEmpty ? (clip.sourceAppName ?? "Edit Clip") : trimmedTitle)
            if textChanged {
                ExternalEditorService.shared.pushFromApp(text: text, clipID: id)
            }
        }
        if let failure = applyPendingEffects() {
            saveError = failure
            return false
        }
        EditorDraftStore.shared.remove(clipID: id)
        saveError = nil
        return true
    }

    var statsSummary: String {
        "\(pluralize(unicodeCount, "Unicode scalar"))  |  \(pluralize(wordCount, "word"))  |  \(pluralize(lineCount, "line"))"
    }

    /// One pass each over the text for the footer counts. Word count counts
    /// runs of non-whitespace, so multiple/Unicode whitespace between words is
    /// collapsed rather than producing empty tokens.
    static func stats(for text: String) -> (unicode: Int, words: Int, lines: Int) {
        let unicode = text.unicodeScalars.count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (unicode, words, lines)
    }

    /// "1 line" / "2 lines": appends "s" only when the count is not 1.
    func pluralize(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
