import Foundation
import GRDB
import os

/// Loads the list window ClipStore observes (the newest `limit` clips plus every
/// categorized clip) and decodes only the rows that changed since its last load.
///
/// Every write to `clips` re-runs the observation: each capture, each OCR result,
/// each rename. Fetching the window with `SELECT *` decoded every categorized clip
/// on every pulse, rich-text and HTML blobs included. The loader reads the window's
/// `(id, rowVersion)` stamps first (the version lives in `clip_version`, bumped by
/// the `clip_version_bump` trigger on every update, from any writer), then fetches
/// light rows (no RTF/HTML blobs, see `Clip.light`) only for ids it has not seen or whose version moved. Unchanged rows
/// are reused.
///
/// Clip ids are never reused (AUTOINCREMENT), so an id and a version name one row
/// state. A backup restore replaces the contents wholesale; `generation` (see
/// `ClipDatabase.contentGeneration`) drops the cache when that happens.
final class ClipWindowLoader: Sendable {
    /// One row of the window: its id and change counter.
    struct Stamp: Hashable, Sendable {
        let id: Int64
        let version: Int64
    }

    /// The window's stamps, newest first. Same membership and order as the
    /// window the panel shows. The INDEXED BY hint is required: without it the
    /// planner sorts in a temp b-tree and reads createdAt from every row.
    static let stampsSQL = """
        SELECT c.id, COALESCE(v.version, 0) AS rowVersion FROM clips c INDEXED BY index_clips_on_createdAt
        LEFT JOIN clip_version v ON v.clipID = c.id
        WHERE c.id IN (SELECT clipID FROM clip_category
                       UNION SELECT id FROM (SELECT id FROM clips ORDER BY createdAt DESC, id DESC LIMIT ?))
        ORDER BY c.createdAt DESC, c.id DESC
        """

    /// Ids per `IN (...)` fetch, well under SQLite's bound-parameter limit.
    private static let chunkSize = 500

    private struct State {
        var generation = 0
        var rows: [Int64: (version: Int64, clip: Clip)] = [:]
        var decodedRowCount = 0
    }

    // Held for the whole load so two overlapping loads cannot interleave their
    // stale checks and cache updates.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Full rows decoded by the most recent `load`.
    var lastDecodedRowCount: Int { state.withLock { $0.decodedRowCount } }

    func load(_ db: Database, limit: Int, generation: Int) throws -> ClipWindow {
        try state.withLockUnchecked { state in
            if state.generation != generation {
                state = State(generation: generation)
            }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
            let stamps = try Row.fetchAll(db, sql: Self.stampsSQL, arguments: [limit]).map { row in
                Stamp(id: row["id"], version: row["rowVersion"])
            }
            let stale = stamps.filter { state.rows[$0.id]?.version != $0.version }.map(\.id)
            var fresh: [Int64: (version: Int64, clip: Clip)] = [:]
            for start in stride(from: 0, to: stale.count, by: Self.chunkSize) {
                let chunk = Array(stale[start..<min(start + Self.chunkSize, stale.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(Clip.lightColumns(alias: "c")), COALESCE(v.version, 0) AS rowVersion FROM clips c
                        LEFT JOIN clip_version v ON v.clipID = c.id WHERE c.id IN (\(marks))
                        """,
                    arguments: StatementArguments(chunk))
                for row in rows {
                    let clip = try Clip.light(row)
                    let version: Int64 = row["rowVersion"]
                    if let id = clip.id { fresh[id] = (version, clip) }
                }
            }
            // Rebuilt from the stamps so rows that left the window leave the cache.
            var next: [Int64: (version: Int64, clip: Clip)] = [:]
            next.reserveCapacity(stamps.count)
            var clips: [Clip] = []
            clips.reserveCapacity(stamps.count)
            for stamp in stamps {
                guard let entry = fresh[stamp.id] ?? state.rows[stamp.id] else { continue }
                next[stamp.id] = entry
                clips.append(entry.clip)
            }
            state.rows = next
            state.decodedRowCount = fresh.count
            return ClipWindow(clips: clips, stamps: stamps, total: total)
        }
    }
}

/// The observed list window: recents plus every categorized clip, and the table size.
/// Equal stamps mean the same rows at the same versions, so comparing them stands in
/// for comparing every clip's content (blobs included) on each pulse.
struct ClipWindow: Equatable {
    var clips: [Clip]
    var stamps: [ClipWindowLoader.Stamp]
    var total: Int

    static func == (lhs: ClipWindow, rhs: ClipWindow) -> Bool {
        lhs.total == rhs.total && lhs.stamps == rhs.stamps
    }
}
