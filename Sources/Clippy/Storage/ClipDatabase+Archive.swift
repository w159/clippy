import Foundation
import GRDB

// Database side of the clippy archive: reading categories with their clips for
// export, and idempotent upserts for import. Import is deliberately
// non-destructive: existing categories (matched by name, case-insensitively) are
// updated in place and identical clips (same text / same content-hash media) are
// reused, with metadata merged newest-wins, so re-importing an edited archive
// (or syncing two Macs) does not pile up duplicates.
//
// The upserts are `static` and take a `Database` so ClippyArchive can run the
// whole import inside ONE write transaction (DAT-08): an import that throws
// midway rolls back completely instead of leaving a partial import.
extension ClipDatabase {

    // MARK: - Export

    /// Every category in display order, each paired with its clips in the
    /// category's own `sortOrder` (DAT-09). The unit the archive is built from.
    ///
    /// Sensitive clips (SEC-02: `SensitiveContent.isSensitive(clip:)`) are left out
    /// by default, so neither the iCloud package nor a manual export carries
    /// client NPI or secrets off this Mac. Pass `excludingSensitive: false` only
    /// for an explicit, user-confirmed full backup.
    func clipsGroupedByCategory(
        excludingSensitive: Bool = true,
        isSensitive: (Clip) -> Bool = { SensitiveContent.isSensitive(clip: $0) }
    ) throws -> [(category: Category, clips: [Clip])] {
        let grouped: [(category: Category, clips: [Clip])] = try dbQueue.read { connection in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(connection)
            var result: [(category: Category, clips: [Clip])] = []
            for category in categories {
                guard let id = category.id else { continue }
                let clips = try Clip.fetchAll(
                    connection,
                    sql: """
                        SELECT clips.* FROM clips
                        JOIN clip_category ON clip_category.clipID = clips.id
                        WHERE clip_category.categoryID = ?
                        ORDER BY clip_category.sortOrder ASC, clip_category.addedAt DESC, clips.id DESC
                        """,
                    arguments: [id]
                )
                result.append((category, clips))
            }
            return result
        }
        guard excludingSensitive else { return grouped }
        return grouped.map { (category: $0.category, clips: $0.clips.filter { !isSensitive($0) }) }
    }

    // MARK: - Import (transaction-scoped)

    /// Find a category by name (case-insensitive) and update its style/order, or
    /// create it. The `starter` flag only takes effect when no starter exists yet
    /// (the schema allows at most one).
    static func upsertImportedCategory(
        _ db: Database,
        name: String,
        colorHex: String,
        iconKind: CategoryIconKind,
        iconValue: String,
        position: Int,
        starter: Bool
    ) throws -> Int64 {
        if var existing = try Category.filter(Column("name").collating(.nocase) == name).fetchOne(db) {
            existing.colorHex = colorHex
            existing.iconKind = iconKind
            existing.iconValue = iconValue
            existing.sortOrder = position
            try existing.update(db)
            return existing.id ?? -1
        }
        var makeStarter = false
        if starter {
            let hasStarter = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM category WHERE isStarter = 1)"
            ) ?? false
            makeStarter = !hasStarter
        }
        var category = Category(
            id: nil, name: name, colorHex: colorHex,
            iconKind: iconKind, iconValue: iconValue,
            sortOrder: position, isStarter: makeStarter, createdAt: Date()
        )
        try category.insert(db)
        return category.id ?? -1
    }

    /// Newest-wins metadata merge for a clip that already exists locally: the
    /// incoming title/source app/date replace the stored ones only when the
    /// incoming copy is newer; a missing local title is always filled.
    private static func mergeMetadata(
        _ db: Database, into existing: Clip, title: String?, sourceApp: String?, createdAt: Date
    ) throws {
        guard let id = existing.id else { return }
        if createdAt > existing.createdAt {
            try db.execute(
                sql: """
                    UPDATE clips SET createdAt = ?,
                        userTitle = COALESCE(?, userTitle),
                        sourceAppName = COALESCE(?, sourceAppName)
                    WHERE id = ?
                    """,
                arguments: [createdAt, title, sourceApp, id]
            )
        } else if existing.userTitle == nil, let title {
            try db.execute(sql: "UPDATE clips SET userTitle = ? WHERE id = ?", arguments: [title, id])
        }
    }

    /// Reuse an identical text clip if present, merging metadata; otherwise
    /// insert. Cap/ceiling eviction runs once at the end of the import.
    static func upsertImportedTextClip(
        _ db: Database, text: String, title: String?, sourceApp: String?, createdAt: Date
    ) throws -> Int64 {
        if let existing = try Clip.duplicateText(of: text).fetchOne(db) {
            try mergeMetadata(db, into: existing, title: title, sourceApp: sourceApp, createdAt: createdAt)
            return existing.id ?? -1
        }
        var clip = Clip(
            id: nil, contentText: text, contentRTF: nil, contentHTML: nil,
            typeIdentifier: "public.utf8-plain-text",
            sourceAppBundleID: nil, sourceAppName: sourceApp,
            createdAt: createdAt, contentKind: .text,
            mediaFilename: nil, thumbFilename: nil,
            pixelWidth: nil, pixelHeight: nil, byteSize: nil, userTitle: title
        )
        try clip.insert(db)
        return clip.id ?? -1
    }

    /// Insert (or merge into) an image clip whose bytes are already stored in
    /// the media store.
    static func upsertImportedImageClip(
        _ db: Database, stored: MediaStore.StoredImage, title: String?, sourceApp: String?, createdAt: Date
    ) throws -> Int64 {
        if let existing = try Clip.duplicateImage(mediaFilename: stored.mediaFilename).fetchOne(db) {
            try mergeMetadata(db, into: existing, title: title, sourceApp: sourceApp, createdAt: createdAt)
            return existing.id ?? -1
        }
        var clip = Clip(
            id: nil, contentText: "", contentRTF: nil, contentHTML: nil,
            typeIdentifier: "public.png",
            sourceAppBundleID: nil, sourceAppName: sourceApp,
            createdAt: createdAt, contentKind: .image,
            mediaFilename: stored.mediaFilename, thumbFilename: stored.thumbFilename,
            pixelWidth: stored.pixelWidth, pixelHeight: stored.pixelHeight,
            byteSize: stored.byteSize, userTitle: title
        )
        try clip.insert(db)
        return clip.id ?? -1
    }

    /// Insert (or merge into) a file clip. `stored` is set when the archive
    /// carried the file's bytes; otherwise the clip is a path reference.
    static func upsertImportedFileClip(
        _ db: Database, displayName: String, filePath: String?, stored: MediaStore.StoredFile?,
        title: String?, sourceApp: String?, createdAt: Date
    ) throws -> Int64 {
        let request = Clip.duplicateFile(mediaFilename: stored?.mediaFilename, filePath: filePath)
        if let existing = try request.fetchOne(db) {
            try mergeMetadata(db, into: existing, title: title, sourceApp: sourceApp, createdAt: createdAt)
            return existing.id ?? -1
        }
        var clip = Clip(
            id: nil, contentText: displayName, contentRTF: nil, contentHTML: nil,
            typeIdentifier: "public.file-url",
            sourceAppBundleID: nil, sourceAppName: sourceApp,
            createdAt: createdAt, contentKind: .file,
            mediaFilename: stored?.mediaFilename, thumbFilename: stored?.thumbFilename,
            pixelWidth: stored?.pixelWidth, pixelHeight: stored?.pixelHeight,
            byteSize: stored?.byteSize, userTitle: title
        )
        clip.filePath = filePath
        try clip.insert(db)
        return clip.id ?? -1
    }

    /// File a clip into a category at `position` (new memberships only; an
    /// existing membership keeps the user's order).
    static func addImportedMembership(_ connection: Database, clipID: Int64, categoryID: Int64, position: Int) throws {
        try connection.execute(
            sql: "INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt, sortOrder) VALUES (?, ?, ?, ?)",
            arguments: [clipID, categoryID, Date(), position]
        )
    }
}
