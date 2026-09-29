import Foundation
import GRDB

extension ClipDatabase {
    /// Image-like clips never scanned (`ocrText IS NULL`) with an id below
    /// `cursor`, newest id first. Iterating by descending id lets the indexer
    /// skip a clip (sensitive, recognition failure) without seeing it again.
    func clipsNeedingOCR(before cursor: Int64 = .max, limit: Int) throws -> [Clip] {
        try dbQueue.read { db in
            try Clip.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE ocrText IS NULL AND mediaFilename IS NOT NULL AND id < ?
                      AND (contentKind = 'image' OR (contentKind = 'file' AND thumbFilename IS NOT NULL))
                    ORDER BY id DESC LIMIT ?
                    """,
                arguments: [cursor, limit])
        }
    }

    /// Stores recognised text ("" = scanned, nothing found). The FTS triggers
    /// keep the index in sync. No-op if the clip was deleted meanwhile.
    func setOCRText(id: Int64, text: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clips SET ocrText = ? WHERE id = ?", arguments: [text, id])
        }
    }

    /// Forgets all recognised text so the indexer rescans (used when the user
    /// turns indexing off and wants the data gone).
    func clearAllOCRText() throws {
        try dbQueue.write { db in try db.execute(sql: "UPDATE clips SET ocrText = NULL") }
    }
}
