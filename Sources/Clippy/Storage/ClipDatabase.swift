import Foundation
import GRDB

/// All persistence. SQLite via GRDB, with an FTS5 index kept in sync with the
/// clips table for full-text search. Unencrypted for milestone 1; SQLCipher
/// swaps in behind this same interface later.
final class ClipDatabase {
    /// The error from the most recent attempt to open the on-disk database, if
    /// it failed. AppDelegate reads this at launch to present a recovery alert
    /// (Show in Finder / Retry / Quit) instead of the process crashing via
    /// fatalError. Reset to nil on a successful retry.
    static var loadError: Error?

    /// Backing cache for `shared`. guarded by `sharedLock` so concurrent
    /// first-access from off-main threads is safe.
    private static var _shared: ClipDatabase?
    private static let sharedLock = NSLock()

    /// On-disk singleton. Preserved as a non-optional accessor so existing
    /// call sites compile unchanged. When the on-disk database cannot be
    /// opened, the error is stored in `loadError` and an in-memory sentinel is
    /// returned instead, so the app can run its launch sequence and show the
    /// recovery alert rather than crashing. Callers that want to handle the
    /// failure explicitly should use `loadShared()`.
    static var shared: ClipDatabase {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let cached = _shared { return cached }
        do {
            let db = try ClipDatabase()
            _shared = db
            return db
        } catch {
            loadError = error
            ClippyLog.error("Clippy could not open its database: \(error)", category: ClippyLog.storage)
            let sentinel = makeRecoverySentinel()
            _shared = sentinel
            return sentinel
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
        sharedLock.lock()
        defer { sharedLock.unlock() }
        do {
            let db = try ClipDatabase()
            _shared = db
            loadError = nil
            return db
        } catch {
            loadError = error
            ClippyLog.error("Clippy database retry failed: \(error)", category: ClippyLog.storage)
            return nil
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

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: ":memory:")
            // Best-effort migrations; a failure here leaves an empty in-memory
            // schema, which is fine because the app is about to show the
            // recovery alert and will not read/write clips against the sentinel.
            try? Self.makeMigrator().migrate(queue)
        } catch {
            // Extremely unlikely (in-memory open basically never fails); fall
            // back to a fresh in-memory queue without migrations. Force-try is
            // safe because :memory: open cannot fail, and this recovery path
            // must not itself throw.
            queue = try! DatabaseQueue(path: ":memory:")
        }
        // Temp directory is always writable; the recovery path must not itself
        // throw, so use a force-try on a guaranteed location.
        let media = try! MediaStore(directory: mediaDir)
        return ClipDatabase(queue: queue, url: dbURL, media: media)
    }

    let dbQueue: DatabaseQueue
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
        dbQueue = try DatabaseQueue(path: self.databaseURL.path)
        try Self.makeMigrator().migrate(dbQueue)
    }

    /// Private init used by the recovery sentinel: assemble from pre-built
    /// pieces so no on-disk open is attempted.
    private init(queue: DatabaseQueue, url: URL, media: MediaStore) {
        self.dbQueue = queue
        self.databaseURL = url
        self.media = media
    }

    /// Static so tests can run migrations stepwise without building a full ClipDatabase.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentText", .text).notNull()
                t.column("contentRTF", .blob)
                t.column("contentHTML", .blob)
                t.column("typeIdentifier", .text).notNull()
                t.column("sourceAppBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "clips", columns: ["createdAt"])
            try db.create(virtualTable: "clips_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clips")
                t.tokenizer = .unicode61()
                t.column("contentText")
            }
        }
        migrator.registerMigration("v2-categories") { db in
            try db.create(table: "category") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("iconKind", .text).notNull()
                t.column("iconValue", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isStarter", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "clip_category") { t in
                t.column("clipID", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                t.column("categoryID", .integer).notNull()
                    .references("category", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["clipID", "categoryID"])
            }
            try db.create(indexOn: "clip_category", columns: ["clipID"])
            // At most one starter category, enforced by the schema.
            try db.execute(
                sql: "CREATE UNIQUE INDEX category_single_starter ON category (isStarter) WHERE isStarter = 1"
            )
            // Starter category receives every legacy pinned clip so nothing
            // is lost; users can rename or restyle it later.
            try db.execute(
                sql: """
                    INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                    VALUES ('Pinned', '#FF9500', 'symbol', 'pin.fill', 0, 1, ?)
                    """,
                arguments: [Date()]
            )
            let starterID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO clip_category (clipID, categoryID, addedAt)
                    SELECT id, ?, ? FROM clips WHERE isPinned = 1
                    """,
                arguments: [starterID, Date()]
            )
            try db.alter(table: "clips") { t in
                t.drop(column: "isPinned")
            }
        }
        migrator.registerMigration("v3-image-clips") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "contentKind", .text).notNull().defaults(to: "text")
                t.add(column: "mediaFilename", .text)
                t.add(column: "thumbFilename", .text)
                t.add(column: "pixelWidth", .integer)
                t.add(column: "pixelHeight", .integer)
                t.add(column: "byteSize", .integer)
            }
        }
        migrator.registerMigration("v4-user-titles") { db in
            // Add the nullable userTitle column; existing rows stay NULL which
            // makes them fall back to sourceAppName in the UI (no data loss).
            try db.alter(table: "clips") { t in
                t.add(column: "userTitle", .text)
            }
            // FTS5 synchronized tables cannot have columns added after creation,
            // so drop and recreate the virtual table to pick up userTitle.
            // GRDB's synchronize() creates three triggers on the content table;
            // they must be dropped explicitly before the FTS table is removed,
            // otherwise the subsequent CREATE VIRTUAL TABLE will try to create
            // them again and hit "trigger already exists".
            try db.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_ai\"")
            try db.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_ad\"")
            try db.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_au\"")
            try db.execute(sql: "DROP TABLE IF EXISTS clips_fts")
            try db.create(virtualTable: "clips_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clips")
                t.tokenizer = .unicode61()
                t.column("contentText")
                t.column("userTitle")
            }
        }
        migrator.registerMigration("v5-clip-category-sort-order") { db in
            // Add per-category clip ordering to the junction table. SQLite's
            // ALTER TABLE does not support NOT NULL without a default on
            // existing tables, so DEFAULT 0 is required here.
            try db.execute(sql: """
                ALTER TABLE clip_category ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0
                """)
            // Backfill: within each category, assign sortOrder by addedAt DESC
            // so the most-recently-added clip appears first (matching the
            // pre-reorder visible order). Gap-free 0-based integers per category.
            try db.execute(sql: """
                UPDATE clip_category
                SET sortOrder = (
                    SELECT COUNT(*) - 1 - ranked.rn
                    FROM (
                        SELECT clipID, categoryID,
                               ROW_NUMBER() OVER (
                                   PARTITION BY categoryID
                                   ORDER BY addedAt DESC
                               ) - 1 AS rn
                        FROM clip_category AS inner_cc
                    ) AS ranked
                    WHERE ranked.clipID = clip_category.clipID
                      AND ranked.categoryID = clip_category.categoryID
                )
                """)
            try db.create(indexOn: "clip_category", columns: ["categoryID", "sortOrder"])
        }
        migrator.registerMigration("v6-file-clips") { db in
            // Add the nullable filePath column for file clips. Additive only;
            // existing text and image rows simply get NULL here.
            try db.alter(table: "clips") { t in
                t.add(column: "filePath", .text)
            }
        }
        return migrator
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
        try dbQueue.write { db in
            if var existing = try request.fetchOne(db) {
                existing.createdAt = newClip.createdAt
                existing.sourceAppBundleID = newClip.sourceAppBundleID
                existing.sourceAppName = newClip.sourceAppName
                try existing.update(db)
                return
            }
            var inserting = newClip
            try inserting.insert(db)
            evicted = try Self.evictOverCap(db, cap: cap)
            // Absolute ceiling: if total rows still exceed the hard limit after
            // the normal cap eviction (because categorized clips are exempt from
            // the cap), delete the oldest categorized clips beyond that ceiling
            // too. This prevents unbounded growth when users heavily categorize.
            evicted += try Self.evictAbsoluteCeiling(db)
        }
        media.delete(filenames: evicted)
    }

    /// Deletes uncategorized clips beyond the cap, oldest first, and returns
    /// the media filenames of evicted image clips so callers can remove files.
    /// Clips in any category never count against the cap.
    @discardableResult
    static func evictOverCap(_ db: Database, cap: Int) throws -> [String] {
        guard cap > 0 else { return [] }
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
            db,
            sql: """
                SELECT mediaFilename FROM clips
                WHERE mediaFilename IS NOT NULL AND id IN (\(doomedSQL))
                UNION ALL
                SELECT thumbFilename FROM clips
                WHERE thumbFilename IS NOT NULL AND id IN (\(doomedSQL))
                """
        )
        try db.execute(sql: "DELETE FROM clips WHERE id IN (\(doomedSQL))")
        return filenames
    }

    /// Hard ceiling across ALL clips (including categorized) so the table can
    /// never grow without bound even when every clip is in a category and the
    /// normal cap eviction leaves them all in place.
    /// Evicts the oldest clips beyond the ceiling and returns their media filenames.
    private static let absoluteClipCeiling = 10_000

    @discardableResult
    static func evictAbsoluteCeiling(_ db: Database) throws -> [String] {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
        guard total > absoluteClipCeiling else { return [] }

        let excess = total - absoluteClipCeiling
        // Delete the oldest clips (by createdAt) regardless of category membership.
        let ceilingDoomedSQL = """
            SELECT id FROM clips
            ORDER BY createdAt ASC, id ASC
            LIMIT \(excess)
            """
        let filenames = try String.fetchAll(
            db,
            sql: """
                SELECT mediaFilename FROM clips
                WHERE mediaFilename IS NOT NULL AND id IN (\(ceilingDoomedSQL))
                UNION ALL
                SELECT thumbFilename FROM clips
                WHERE thumbFilename IS NOT NULL AND id IN (\(ceilingDoomedSQL))
                """
        )
        try db.execute(sql: "DELETE FROM clips WHERE id IN (\(ceilingDoomedSQL))")
        if excess > 0 {
            ClippyLog.info("Absolute ceiling eviction: removed \(excess) clips (total was \(total))",
                           category: ClippyLog.storage)
        }
        return filenames
    }

    /// User edited the text in the plain-text editor. The original rich blobs
    /// no longer match the text, so they are dropped on purpose.
    func updateClipText(id: Int64, newText: String) throws {
        try dbQueue.write { db in
            try db.execute(
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
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clips SET userTitle = ? WHERE id = ?",
                arguments: [userTitle, id]
            )
        }
    }

    /// User edited an image clip. New media files are written by MediaStore
    /// BEFORE this runs; the row is repointed at them and the now-unreferenced old
    /// files are deleted (unless the new content hashes to the same filename).
    func updateClipImage(id: Int64, stored: MediaStore.StoredImage) throws {
        let oldFilenames: [String] = try dbQueue.write { db in
            let existing = try Clip.fetchOne(db, key: id)
            try db.execute(
                sql: """
                    UPDATE clips
                    SET mediaFilename = ?, thumbFilename = ?, pixelWidth = ?, pixelHeight = ?, byteSize = ?,
                        typeIdentifier = 'public.png', contentKind = ?
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
    func insertTextClip(_ text: String, sourceAppName: String = "Clippy Scripts") throws -> Int64 {
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
        try dbQueue.write { db in
            try clip.insert(db)
        }
        return clip.id ?? 0
    }

    func deleteClip(id: Int64) throws {
        let filenames: [String] = try dbQueue.write { db in
            let clip = try Clip.fetchOne(db, key: id)
            try Clip.deleteOne(db, key: id)
            return clip?.mediaFilenames ?? []
        }
        media.delete(filenames: filenames)
    }

    func deleteUnclassifiedClips() throws {
        let filenames: [String] = try dbQueue.write { db in
            let doomed = try Clip
                .filter(sql: "id NOT IN (SELECT clipID FROM clip_category)")
                .fetchAll(db)
            try db.execute(sql: "DELETE FROM clips WHERE id NOT IN (SELECT clipID FROM clip_category)")
            return doomed.flatMap(\.mediaFilenames)
        }
        media.delete(filenames: filenames)
    }

    /// Every media filename any clip references, for the launch orphan sweep.
    func referencedMediaFilenames() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT mediaFilename, thumbFilename FROM clips WHERE mediaFilename IS NOT NULL OR thumbFilename IS NOT NULL"
            )
            var names = Set<String>()
            for row in rows {
                if let m: String = row["mediaFilename"] { names.insert(m) }
                if let t: String = row["thumbFilename"] { names.insert(t) }
            }
            return names
        }
    }

    // MARK: - Reads

    func allClips() throws -> [Clip] {
        try dbQueue.read { db in
            try Clip.order(Column("createdAt").desc, Column("id").desc).fetchAll(db)
        }
    }

    /// Searches clips with the `#`-token grammar (see ClipQueryParser). Free text
    /// goes through FTS5; `#kind` tokens filter contentKind (derived kinds like
    /// `#link` finish in Swift); `#app` filters match sourceAppName/bundleID; a
    /// `#duration` token bounds createdAt. Filter-only queries (no free text) are
    /// supported and ordered newest-first instead of by FTS rank.
    func searchClips(matching query: String, limit: Int) throws -> [Clip] {
        let parsed = ClipQueryParser.parse(query)
        // Derived kinds (#link/#email/#color/#path) match a subset of the text
        // rows the SQL narrows to, so over-fetch and trim after the Swift pass.
        let needsKindPostFilter = parsed.kinds.contains(where: \.isDerived)
        let fetchLimit = needsKindPostFilter ? limit * 4 : limit
        let fetched = try dbQueue.read { db -> [Clip] in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            var joinFTS = false
            var orderByRank = false

            if !parsed.text.isEmpty, let pattern = FTS5Pattern(matchingAllPrefixesIn: parsed.text) {
                joinFTS = true
                orderByRank = true
                clauses.append("clips_fts MATCH ?")
                args.append(pattern)
            }

            if !parsed.kinds.isEmpty {
                let stored = Set(parsed.kinds.map { $0.storedContentKind.rawValue }).sorted()
                let placeholders = stored.map { _ in "?" }.joined(separator: ", ")
                clauses.append("clips.contentKind IN (\(placeholders))")
                args.append(contentsOf: stored)
            }

            if !parsed.sourceApps.isEmpty {
                let perApp = parsed.sourceApps.map { _ in
                    "(clips.sourceAppName LIKE ? OR clips.sourceAppBundleID LIKE ?)"
                }
                clauses.append("(" + perApp.joined(separator: " OR ") + ")")
                for app in parsed.sourceApps {
                    let like = "%\(app)%"
                    args.append(like)
                    args.append(like)
                }
            }

            if let since = parsed.since {
                clauses.append("clips.createdAt >= ?")
                args.append(since)
            }

            // No usable predicate (e.g. only an unmatched FTS pattern): fall back to recent.
            guard !clauses.isEmpty else {
                return try Clip.order(Column("createdAt").desc, Column("id").desc)
                    .limit(limit)
                    .fetchAll(db)
            }

            var sql = "SELECT clips.* FROM clips"
            if joinFTS { sql += " JOIN clips_fts ON clips_fts.rowid = clips.id" }
            sql += " WHERE " + clauses.joined(separator: " AND ")
            sql += orderByRank ? " ORDER BY rank" : " ORDER BY clips.createdAt DESC, clips.id DESC"
            sql += " LIMIT ?"
            args.append(fetchLimit)

            return try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        guard !parsed.kinds.isEmpty else { return fetched }
        // OR semantics across kind tokens, mirroring the app-filter behavior.
        return Array(
            fetched
                .filter { clip in parsed.kinds.contains { $0.matches(clip) } }
                .prefix(limit)
        )
    }

    // MARK: - Category state

    /// Cached after first lookup: the starter category is created in migration
    /// v2 and never deleted, so its id is stable for the process lifetime.
    /// Stored here because extensions cannot declare stored properties; the
    /// category API lives in ClipDatabase+Categories.swift.
    var cachedStarterCategoryID: Int64?
}

extension Clip {
    /// The capture/import dedupe predicate for a text clip: same text, kind text.
    static func duplicateText(of contentText: String) -> QueryInterfaceRequest<Clip> {
        Clip.filter(Column("contentText") == contentText)
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
