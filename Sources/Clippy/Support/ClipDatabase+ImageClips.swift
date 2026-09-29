import Foundation
import GRDB

extension ClipDatabase {
    /// Cheap existence probe for image clips, used by the OCR warm-up policy.
    /// Reads a single row and never loads clip payloads.
    func hasImageClips() -> Bool {
        let found = try? dbQueue.read { connection in
            try Clip.filter(Column("contentKind") == ClipContentKind.image.rawValue).isEmpty(connection) == false
        }
        return found ?? false
    }
}

/// Answers "are there image clips?" from memory so `panelDidShow()` never waits
/// on the database queue (a capture write or export holding it stalled panel
/// show). Each call returns the last known answer and refreshes it off-main.
final class CachedImageClipProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private let database: ClipDatabase

    init(database: ClipDatabase) { self.database = database }

    /// Last known answer; schedules a background refresh.
    func current() -> Bool {
        refresh()
        return lock.withLock { value }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = database.hasImageClips()
            lock.withLock { value = found }
        }
    }
}
