import Foundation
import GRDB

extension ClipDatabase {
    /// The newest `limit` clips, newest first, without loading the whole table.
    func recentClips(limit: Int, offset: Int = 0) throws -> [Clip] {
        try dbQueue.read { connection in
            try Clip.order(Column("createdAt").desc, Column("id").desc).limit(limit, offset: offset).fetchAll(connection)
        }
    }
}
