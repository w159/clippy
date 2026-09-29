import Foundation
import GRDB

extension ClipDatabase {
    /// Newest text clips for the action editor's test picker. A bounded read, not
    /// `allClips()`, so opening the editor does not load the whole history.
    func recentTextClips(limit: Int) throws -> [Clip] {
        try dbQueue.read { database in
            try Clip.order(Column("createdAt").desc, Column("id").desc)
                .limit(limit * 3)
                .fetchAll(database)
                .filter { !$0.contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(limit)
                .map { $0 }
        }
    }
}
