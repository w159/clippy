import Foundation
import GRDB

extension ClipDatabase {
    /// One clip by primary key. The agent tools used `allClips().first(where:)`,
    /// which loads the entire history to find one row (AI-11). Kept in AI/ so the
    /// Storage layer is untouched; it goes through the same `dbQueue` reads use.
    func clip(withID id: Int64) throws -> Clip? {
        try dbQueue.read { database in try Clip.fetchOne(database, key: id) }
    }
}
