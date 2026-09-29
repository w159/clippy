import Foundation
import GRDB
import os

/// All persistence. SQLite via GRDB, with an FTS5 index kept in sync with the
/// clips table for full-text search. Unencrypted for milestone 1; SQLCipher
/// swaps in behind this same interface later.
final class ClipDatabase: Sendable {
    /// The error from the most recent attempt to open the on-disk database, if
    /// it failed. AppDelegate reads this at launch to present a recovery alert
    /// (Show in Finder / Retry / Quit) instead of the process crashing via
    /// fatalError. Reset to nil on a successful retry.
    static var loadError: Error? {
        get { loadErrorSlot.withLock { $0 } }
        set { loadErrorSlot.withLock { $0 = newValue } }
    }
    private static let loadErrorSlot = OSAllocatedUnfairLock<Error?>(initialState: nil)

    /// Backing cache for `shared`. The lock makes concurrent first access from
    /// off-main threads safe: only one caller opens the database.
    private static let sharedInstance = OSAllocatedUnfairLock<ClipDatabase?>(initialState: nil)

    /// On-disk singleton. Preserved as a non-optional accessor so existing
    /// call sites compile unchanged. When the on-disk database cannot be
    /// opened, the error is stored in `loadError` and an in-memory sentinel is
    /// returned instead, so the app can run its launch sequence and show the
    /// recovery alert rather than crashing. Callers that want to handle the
    /// failure explicitly should use `loadShared()`.
    static var shared: ClipDatabase {
        sharedInstance.withLock { slot in
            if let cached = slot { return cached }
            do {
                let connection = try ClipDatabase()
                slot = connection
                return connection
            } catch {
                loadError = error
                ClippyLog.error("Clippy could not open its database: \(error)", category: ClippyLog.storage)
                let sentinel = makeRecoverySentinel()
                slot = sentinel
                return sentinel
            }
        }
    }

    /// Throwing accessor for callers that prefer explicit error handling.
    /// Returns the cached `shared` instance when the on-disk database opened
    /// successfully; rethrows the stored failure otherwise.
    static func loadShared() throws -> ClipDatabase {
        if let error = loadError { throw error }
        return shared
    }

    /// Re-attempt opening the on-disk database after a prior failure (e.g. the
    /// user clicked Retry in the recovery alert). On success, replaces the
    /// cached sentinel with the live database and clears `loadError`. Returns
    /// the new database on success, nil on continued failure.
    @discardableResult
    static func retryLoad() -> ClipDatabase? {
        sharedInstance.withLock { slot in
            do {
                let connection = try ClipDatabase()
                slot = connection
                loadError = nil
                return connection
            } catch {
                loadError = error
                ClippyLog.error("Clippy database retry failed: \(error)", category: ClippyLog.storage)
                return nil
            }
        }
    }

    /// In-memory fallback used only when the on-disk database cannot be opened.
    /// Lets the app run its launch sequence (status item, menu, recovery alert)
    /// without crashing. The sentinel's databaseURL points at the intended
    /// on-disk path so "Show in Finder" in the recovery alert opens the right
    /// folder; media is a temp directory so nothing is written to disk.
    private static func makeRecoverySentinel() -> ClipDatabase {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        let dbURL = supportDir.appendingPathComponent("clippy.sqlite")
        let mediaDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyRecoveryMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // Best-effort migrations; a failure leaves an empty in-memory schema,
        // which is fine because the app shows the recovery alert and never
        // reads/writes clips against the sentinel.
        guard let queue = try? DatabaseQueue(path: ":memory:") else {
            preconditionFailure("SQLite could not open an in-memory database; nothing to recover into")
        }
        try? Self.makeMigrator().migrate(queue)
        // Fall back to a unique temp directory if the fixed one is unusable.
        let fallbackDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyRecoveryMedia-\(UUID().uuidString)", isDirectory: true)
        guard let media = (try? MediaStore(directory: mediaDir)) ?? (try? MediaStore(directory: fallbackDir)) else {
            preconditionFailure("Temporary directory is not writable; cannot build the recovery sentinel")
        }
        return ClipDatabase(queue: queue, url: dbURL, media: media)
    }

    /// The writer every read and write goes through. A `DatabasePool` (WAL,
    /// concurrent readers) for the on-disk database; a `DatabaseQueue` only for
    /// the in-memory recovery sentinel. The name is historical.
    let dbQueue: DatabaseWriter
    let databaseURL: URL
    let media: MediaStore

    init(databaseURL: URL? = nil, mediaDirectory: URL? = nil) throws {
        if let databaseURL, let mediaDirectory {
            self.databaseURL = databaseURL
            self.media = try MediaStore(directory: mediaDirectory)
        } else {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clippy", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            self.databaseURL = databaseURL ?? supportDir.appendingPathComponent("clippy.sqlite")
            self.media = try MediaStore(
                directory: mediaDirectory ?? supportDir.appendingPathComponent("media", isDirectory: true)
            )
        }
        dbQueue = try DatabasePool(path: self.databaseURL.path, configuration: Self.makeConfiguration())
        try Self.makeMigrator().migrate(dbQueue)
    }

    /// Hook run on every new connection before anything else. This is the seam
    /// for encryption at rest (DAT-12, deferred): a SQLCipher build sets it to
    /// `{ db in try db.usePassphrase(key) }` and every pool connection (writer
    /// and readers) is keyed identically, without touching any caller.
    static var prepareConnection: (@Sendable (Database) throws -> Void)? {
        get { prepareConnectionSlot.withLock { $0 } }
        set { prepareConnectionSlot.withLock { $0 = newValue } }
    }
    private static let prepareConnectionSlot =
        OSAllocatedUnfairLock<(@Sendable (Database) throws -> Void)?>(initialState: nil)

    /// WAL journal (implicit for `DatabasePool`) plus a 5s busy timeout, because
    /// two processes (the app and the MCP server) write to this file (DAT-13).
    static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { connection in
            try prepareConnection?(connection)
        }
        return config
    }

    /// Private init used by the recovery sentinel: assemble from pre-built
    /// pieces so no on-disk open is attempted.
    private init(queue: DatabaseWriter, url: URL, media: MediaStore) {
        self.dbQueue = queue
        self.databaseURL = url
        self.media = media
    }


    // MARK: - Writes

    /// Insert a freshly captured clip. A duplicate of an existing clip is not
    /// re-inserted; its timestamp is bumped so it surfaces at the top.
    func saveCapturedClip(_ clip: inout Clip, cap: Int) throws {
        try upsertCaptured(&clip, cap: cap, matchedBy: Clip.duplicateText(of: clip.contentText))
    }

    /// Insert a captured image clip. Media files are written by MediaStore
    /// BEFORE this runs. Dedupe key is the content-hash filename; a re-copy
    /// bumps the timestamp.
    func saveCapturedImageClip(_ clip: inout Clip, cap: Int) throws {
        try upsertCaptured(&clip, cap: cap, matchedBy: Clip.duplicateImage(mediaFilename: clip.mediaFilename))
    }

    /// Insert a captured file clip. When bytes were stored, the dedupe key is
    /// the content-hash mediaFilename (same file re-copied bumps the timestamp).
    /// When only a path reference was kept, the dedupe key is the filePath.
    func saveCapturedFileClip(_ clip: inout Clip, cap: Int) throws {
        try upsertCaptured(&clip, cap: cap, matchedBy: Clip.duplicateFile(
            mediaFilename: clip.mediaFilename,
            filePath: clip.filePath
        ))
    }

    /// Shared capture body: bump-on-duplicate, else insert + evict over cap, then
    /// delete the media files freed by eviction. The dedupe predicate is the only
    /// thing that differs between text and image capture.
    private func upsertCaptured(_ clip: inout Clip, cap: Int,
                                matchedBy request: QueryInterfaceRequest<Clip>) throws {
        let newClip = clip
        var evicted: [String] = []
        var savedID: Int64?
        try dbQueue.write { connection in
            if var existing = try request.fetchOne(connection) {
                existing.createdAt = newClip.createdAt
                existing.sourceAppBundleID = newClip.sourceAppBundleID
                existing.sourceAppName = newClip.sourceAppName
                try existing.update(connection)
                savedID = existing.id
                return
            }
            var inserting = newClip
            try inserting.insert(connection)
            savedID = inserting.id
            evicted = try Self.enforceLimits(connection, cap: cap)
        }
        // Report the row id (inserted or bumped) to the caller, e.g. for the
        // clippyClipCaptured notification.
        clip.id = savedID
        media.delete(filenames: evicted)
    }

    /// Deletes uncategorized clips beyond the cap, oldest first, and returns
    /// the media filenames of evicted image clips so callers can remove files.
    /// Clips in any category never count against the cap.
    @discardableResult
    static func evictOverCap(_ connection: Database, cap: Int) throws -> [String] {
        guard cap > 0 else { return [] }
        // Common case (under the cap): one cheap count instead of three
        // NOT IN / top-N passes over the whole table.
        let uncategorized = try Int.fetchOne(
            connection,
            sql: "SELECT COUNT(*) FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)") ?? 0
        guard uncategorized > cap else { return [] }
        let doomedSQL = """
            SELECT id FROM clips
            WHERE id NOT IN (SELECT clipID FROM clip_category)
            AND id NOT IN (
                SELECT id FROM clips
                WHERE id NOT IN (SELECT clipID FROM clip_category)
                ORDER BY createdAt DESC, id DESC
                LIMIT \(cap)
            )
            """
        let filenames = try String.fetchAll(
            connection,
            sql: """
                SELECT mediaFilename FROM clips
                WHERE mediaFilename IS NOT NULL AND id IN (\(doomedSQL))
                UNION ALL
                SELECT thumbFilename FROM clips
                WHERE thumbFilename IS NOT NULL AND id IN (\(doomedSQL))
                """
        )
        try connection.execute(sql: "DELETE FROM clips WHERE id IN (\(doomedSQL))")
        return filenames
    }

    /// THE eviction chokepoint (DAT-11). Every path that adds rows (capture,
    /// script/OCR/AI text, archive import, sync) calls this inside the same
    /// transaction as the insert: first the history cap, then the hard ceiling.
    /// Returns media filenames freed, for the caller to delete after commit.
    @discardableResult
    static func enforceLimits(_ connection: Database, cap: Int) throws -> [String] {
        var evicted = try evictOverCap(connection, cap: cap)
        evicted += try evictAbsoluteCeiling(connection)
        return evicted
    }

    /// Hard ceiling on total rows. Evicts the oldest *uncategorized* clips beyond
    /// `ceiling`; pinned/categorized clips are never touched (DAT-06). If those
    /// alone exceed the ceiling the table stays over it and the store warns.
    /// Returns the media filenames of evicted clips.
    @discardableResult
    static func evictAbsoluteCeiling(_ connection: Database, ceiling: Int = StorageCeiling.current) throws -> [String] {
        let total = try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM clips") ?? 0
        guard total > ceiling else { return [] }

        let excess = total - ceiling
        let doomedSQL = """
            SELECT id FROM clips
            WHERE id NOT IN (SELECT clipID FROM clip_category)
            ORDER BY createdAt ASC, id ASC
            LIMIT \(excess)
            """
        let filenames = try String.fetchAll(
            connection,
            sql: """
                SELECT mediaFilename FROM clips
                WHERE mediaFilename IS NOT NULL AND id IN (\(doomedSQL))
                UNION ALL
                SELECT thumbFilename FROM clips
                WHERE thumbFilename IS NOT NULL AND id IN (\(doomedSQL))
                """
        )
        try connection.execute(sql: "DELETE FROM clips WHERE id IN (\(doomedSQL))")
        ClippyLog.info("Ceiling eviction: over by \(excess) (total was \(total))", category: ClippyLog.storage)
        return filenames
    }

    /// Current row count against the configured ceiling, for the 90% warning.
    func storageUsage() throws -> StorageUsage {
        let count = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clips") ?? 0 }
        return StorageUsage(count: count, ceiling: StorageCeiling.current)
    }

    /// Whether a clip row still exists (OCR completion uses this before writing).
    func clipExists(id: Int64) throws -> Bool {
        try dbQueue.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM clips WHERE id = ?)", arguments: [id]) ?? false }
    }

    /// User edited the text in the plain-text editor. The original rich blobs
    /// no longer match the text, so they are dropped on purpose.
    func updateClipText(id: Int64, newText: String) throws {
        try dbQueue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clips
                    SET contentText = ?, contentRTF = NULL, contentHTML = NULL,
                        typeIdentifier = 'public.utf8-plain-text'
                    WHERE id = ?
                    """,
                arguments: [newText, id]
            )
        }
    }

    /// Persists a user-assigned display name. Pass nil to clear the custom title
    /// and revert to showing the source app name in the card header.
    func updateClipTitle(id: Int64, userTitle: String?) throws {
        try dbQueue.write { connection in
            try connection.execute(
                sql: "UPDATE clips SET userTitle = ? WHERE id = ?",
                arguments: [userTitle, id]
            )
        }
    }

    /// User edited an image clip. New media files are written by MediaStore
    /// BEFORE this runs; the row is repointed at them and the now-unreferenced old
    /// files are deleted (unless the new content hashes to the same filename).
    func updateClipImage(id: Int64, stored: MediaStore.StoredImage) throws {
        let oldFilenames: [String] = try dbQueue.write { connection in
            let existing = try Clip.fetchOne(connection, key: id)
            try connection.execute(
                sql: """
                    UPDATE clips
                    SET mediaFilename = ?, thumbFilename = ?, pixelWidth = ?, pixelHeight = ?, byteSize = ?,
                        typeIdentifier = 'public.png', contentKind = ?, ocrText = NULL
                    WHERE id = ?
                    """,
                arguments: [stored.mediaFilename, stored.thumbFilename,
                            stored.pixelWidth, stored.pixelHeight, stored.byteSize,
                            ClipContentKind.image.rawValue, id]
            )
            return existing?.mediaFilenames ?? []
        }
        let keep: Set<String> = [stored.mediaFilename, stored.thumbFilename]
        media.delete(filenames: oldFilenames.filter { !keep.contains($0) })
    }

    /// Insert a plain-text clip from a non-capture source (script output, OCR,
    /// etc.). Unlike saveCapturedClip, this always inserts a fresh row — no
    /// deduplication. Returns the row's assigned id.
    /// - Parameters:
    ///   - text: The clip's text content.
    ///   - sourceAppName: Label shown in the card header. Defaults to "Clippy Scripts"
    ///     for backward compatibility with callers that do not supply one.
    @discardableResult
    func insertTextClip(_ text: String, sourceAppName: String = "Clippy Scripts",
                        cap: Int = AppSettings.storedMaxHistoryItems) throws -> Int64 {
        var clip = Clip(
            id: nil,
            contentText: text,
            contentRTF: nil,
            contentHTML: nil,
            typeIdentifier: "public.utf8-plain-text",
            sourceAppBundleID: nil,
            sourceAppName: sourceAppName,
            createdAt: Date()
        )
        var evicted: [String] = []
        try dbQueue.write { connection in
            try clip.insert(connection)
            evicted = try Self.enforceLimits(connection, cap: cap)
        }
        media.delete(filenames: evicted)
        return clip.id ?? 0
    }

    func deleteClip(id: Int64) throws {
        let filenames: [String] = try dbQueue.write { connection in
            let clip = try Clip.fetchOne(connection, key: id)
            try Clip.deleteOne(connection, key: id)
            return clip?.mediaFilenames ?? []
        }
        media.delete(filenames: filenames)
    }

    func deleteUnclassifiedClips() throws {
        let filenames: [String] = try dbQueue.write { connection in
            let doomed = try Clip
                .filter(sql: "id NOT IN (SELECT clipID FROM clip_category)")
                .fetchAll(connection)
            try connection.execute(sql: "DELETE FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)")
            return doomed.flatMap(\.mediaFilenames)
        }
        media.delete(filenames: filenames)
    }

    /// Every media filename any clip references, for the launch orphan sweep.
    func referencedMediaFilenames() throws -> Set<String> {
        try dbQueue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: "SELECT mediaFilename, thumbFilename FROM clips WHERE mediaFilename IS NOT NULL OR thumbFilename IS NOT NULL"
            )
            var names = Set<String>()
            for row in rows {
                if let mediaName: String = row["mediaFilename"] { names.insert(mediaName) }
                if let thumbName: String = row["thumbFilename"] { names.insert(thumbName) }
            }
            return names
        }
    }

    // MARK: - External writes

    /// SQLite's `data_version`, which increments when a connection *other* than
    /// this one commits. Unchanged for our own writes, so it is a false-positive
    /// free signal that the MCP server process has touched the database.
    /// See ExternalChangeWatcher.
    func dataVersion() throws -> Int64 {
        // On the writer connection: only commits from *other* connections (the
        // MCP process) move its data_version; pool readers never commit, so our
        // own writes stay invisible to it.
        try dbQueue.writeWithoutTransaction { connection in
            try Int64.fetchOne(connection, sql: "PRAGMA data_version") ?? 0
        }
    }

    /// Tell GRDB that something it could not see has changed, so every
    /// `ValueObservation` refetches. Required because observation is blind to
    /// commits from other processes.
    func notifyExternalChanges() throws {
        try dbQueue.write { connection in
            try connection.notifyChanges(in: .fullDatabase)
        }
    }

    // MARK: - Reads

    func allClips() throws -> [Clip] {
        try dbQueue.read { connection in
            try Clip.order(Column("createdAt").desc, Column("id").desc).fetchAll(connection)
        }
    }

    // MARK: - Category state

    /// Cached after first lookup: the starter category is created in migration
    /// v2 and never deleted, so its id is stable for the process lifetime.
    /// Stored here because extensions cannot declare stored properties; the
    /// category API lives in ClipDatabase+Categories.swift.
    var cachedStarterCategoryID: Int64? {
        get { starterCategoryIDCache.withLock { $0 } }
        set { starterCategoryIDCache.withLock { $0 = newValue } }
    }
    private let starterCategoryIDCache = OSAllocatedUnfairLock<Int64?>(initialState: nil)
}

extension Clip {
    /// The capture/import dedupe predicate for a text clip: same text, kind text.
    static func duplicateText(of contentText: String) -> QueryInterfaceRequest<Clip> {
        // The prefix predicate lets SQLite use clips_text_prefix instead of
        // comparing every row's (possibly huge) text; equal text implies equal prefix.
        Clip.filter(sql: "substr(contentText, 1, 64) = ?", arguments: [String(contentText.unicodeScalars.prefix(64))])
            .filter(Column("contentText") == contentText)
            .filter(Column("contentKind") == ClipContentKind.text.rawValue)
    }

    /// The capture/import dedupe predicate for an image clip: same media filename
    /// (a content hash), so a re-copy of the same image bumps rather than duplicates.
    static func duplicateImage(mediaFilename: String?) -> QueryInterfaceRequest<Clip> {
        Clip.filter(Column("mediaFilename") == mediaFilename)
    }

    /// The capture/import dedupe predicate for a file clip. When bytes are stored,
    /// match on the content-hash mediaFilename; otherwise match on filePath.
    static func duplicateFile(mediaFilename: String?, filePath: String?) -> QueryInterfaceRequest<Clip> {
        let base = Clip.filter(Column("contentKind") == ClipContentKind.file.rawValue)
        if let mediaFilename {
            return base.filter(Column("mediaFilename") == mediaFilename)
        }
        return base.filter(Column("filePath") == filePath)
    }
}
