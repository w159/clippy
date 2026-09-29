import Foundation
import GRDB

extension ClipEditorPersistence {
    /// Saves a rich-text edit in one transaction: plain text plus the new RTF
    /// blob (the stale HTML flavor is dropped so paste cannot resurrect the
    /// pre-edit formatting), and optionally the title (`title` nil leaves it,
    /// empty clears it).
    func saveRich(id: Int64, text: String, rtf: Data, title: String?) throws {
        try database.dbQueue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clips
                    SET contentText = ?, contentRTF = ?, contentHTML = NULL,
                        typeIdentifier = 'public.rtf'
                    WHERE id = ?
                    """,
                arguments: [text, rtf, id]
            )
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                try connection.execute(
                    sql: "UPDATE clips SET userTitle = ? WHERE id = ?",
                    arguments: [trimmed.isEmpty ? nil : trimmed, id]
                )
            }
        }
    }
}
