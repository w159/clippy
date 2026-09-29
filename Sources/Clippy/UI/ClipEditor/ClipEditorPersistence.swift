import Foundation
import GRDB

/// Database access for the clip editor that ClipStore does not offer: fetch one
/// clip, observe it for external changes (EDT-02), and save text + title in a
/// single transaction (EDT-07).
struct ClipEditorPersistence {
    let database: ClipDatabase

    /// The app-wide database.
    static var live: ClipEditorPersistence { ClipEditorPersistence(database: ClipDatabase.shared) }

    /// The stored clip, or nil when it no longer exists.
    func fetch(id: Int64) -> Clip? {
        try? database.dbQueue.read { try Clip.fetchOne($0, key: id) }
    }

    /// Writes the text and/or title in one transaction, so a failure leaves
    /// neither half applied. `text` nil leaves the text alone (rich blobs are
    /// kept); `title` nil leaves the title alone, and an empty or whitespace
    /// title clears it.
    func save(id: Int64, text: String?, title: String?) throws {
        guard text != nil || title != nil else { return }
        try database.dbQueue.write { connection in
            if let text {
                // Same statement as ClipDatabase.updateClipText: the rich
                // blobs no longer match once the plain text is edited.
                try connection.execute(
                    sql: """
                        UPDATE clips
                        SET contentText = ?, contentRTF = NULL, contentHTML = NULL,
                            typeIdentifier = 'public.utf8-plain-text'
                        WHERE id = ?
                        """,
                    arguments: [text, id]
                )
            }
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                try connection.execute(
                    sql: "UPDATE clips SET userTitle = ? WHERE id = ?",
                    arguments: [trimmed.isEmpty ? nil : trimmed, id]
                )
            }
        }
    }

    /// Calls `onChange` on the main queue with the stored clip (nil once deleted)
    /// now and after every change to its row. Keep the returned token alive.
    func observe(id: Int64, onChange: @escaping (Clip?) -> Void) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking { try Clip.fetchOne($0, key: id) }
            .start(in: database.dbQueue, scheduling: .async(onQueue: .main),
                   onError: { error in
                       ClippyLog.error("editor observation failed: \(error)", category: ClippyLog.storage)
                   },
                   onChange: onChange)
    }
}

/// What the editor should do when the stored clip changes under it (EDT-02).
enum EditorConflictResolution: Equatable {
    /// Stored content equals what the editor was based on: nothing to do.
    case unchanged
    /// Stored content changed and the editor has no edits: silently reload.
    case reload
    /// Stored content changed while the editor holds unsaved edits: ask.
    case conflict
    /// Stored content already equals the editor's text: just move the base.
    case adoptBase
}

enum EditorConflictDetector {
    /// - Parameters:
    ///   - base: the stored text the editor's edits started from.
    ///   - mine: the text currently in the editor.
    ///   - stored: the text now in the database.
    static func evaluate(base: String, mine: String, stored: String) -> EditorConflictResolution {
        if stored == base { return .unchanged }
        if stored == mine { return .adoptBase }
        return mine == base ? .reload : .conflict
    }
}

extension ClipEditorPersistence {
    /// Saves an image editor's changes, writing only what changed (OCR-10):
    /// `png` non-nil stores the new image and repoints the row; `title`
    /// non-nil updates the title (empty clears). Safe to call off the main
    /// thread; a title-only change never encodes or stores an image.
    func saveImage(id: Int64, png: Data?, title: String?) throws {
        if let png {
            let stored = try database.media.store(pngData: png)
            try database.updateClipImage(id: id, stored: stored)
        }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try database.updateClipTitle(id: id, userTitle: trimmed.isEmpty ? nil : trimmed)
        }
    }
}
