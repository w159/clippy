import Foundation
import GRDB

extension ClipDatabase {
    /// Static so tests can run migrations stepwise without building a full ClipDatabase.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerBaseMigrations(&migrator)
        registerImageAndTitleMigrations(&migrator)
        registerFileAndRepairMigrations(&migrator)
        registerOcrAndCollectionMigrations(&migrator)
        return migrator
    }

    /// v1-v2: clips, FTS and categories.
    private static func registerBaseMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { connection in
            try connection.create(table: "clips") { tableBuilder in
                tableBuilder.autoIncrementedPrimaryKey("id")
                tableBuilder.column("contentText", .text).notNull()
                tableBuilder.column("contentRTF", .blob)
                tableBuilder.column("contentHTML", .blob)
                tableBuilder.column("typeIdentifier", .text).notNull()
                tableBuilder.column("sourceAppBundleID", .text)
                tableBuilder.column("sourceAppName", .text)
                tableBuilder.column("createdAt", .datetime).notNull()
                tableBuilder.column("isPinned", .boolean).notNull().defaults(to: false)
            }
            try connection.create(indexOn: "clips", columns: ["createdAt"])
            try connection.create(virtualTable: "clips_fts", using: FTS5()) { tableBuilder in
                tableBuilder.synchronize(withTable: "clips")
                tableBuilder.tokenizer = .unicode61()
                tableBuilder.column("contentText")
            }
        }
        migrator.registerMigration("v2-categories") { connection in
            try connection.create(table: "category") { tableBuilder in
                tableBuilder.autoIncrementedPrimaryKey("id")
                tableBuilder.column("name", .text).notNull()
                tableBuilder.column("colorHex", .text).notNull()
                tableBuilder.column("iconKind", .text).notNull()
                tableBuilder.column("iconValue", .text).notNull()
                tableBuilder.column("sortOrder", .integer).notNull().defaults(to: 0)
                tableBuilder.column("isStarter", .boolean).notNull().defaults(to: false)
                tableBuilder.column("createdAt", .datetime).notNull()
            }
            try connection.create(table: "clip_category") { tableBuilder in
                tableBuilder.column("clipID", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                tableBuilder.column("categoryID", .integer).notNull()
                    .references("category", onDelete: .cascade)
                tableBuilder.column("addedAt", .datetime).notNull()
                tableBuilder.primaryKey(["clipID", "categoryID"])
            }
            try connection.create(indexOn: "clip_category", columns: ["clipID"])
            // At most one starter category, enforced by the schema.
            try connection.execute(
                sql: "CREATE UNIQUE INDEX category_single_starter ON category (isStarter) WHERE isStarter = 1"
            )
            // Starter category receives every legacy pinned clip so nothing
            // is lost; users can rename or restyle it later.
            try connection.execute(
                sql: """
                    INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
                    VALUES ('Pinned', '#FF9500', 'symbol', 'pin.fill', 0, 1, ?)
                    """,
                arguments: [Date()]
            )
            let starterID = connection.lastInsertedRowID
            try connection.execute(
                sql: """
                    INSERT INTO clip_category (clipID, categoryID, addedAt)
                    SELECT id, ?, ? FROM clips WHERE isPinned = 1
                    """,
                arguments: [starterID, Date()]
            )
            try connection.alter(table: "clips") { tableBuilder in
                tableBuilder.drop(column: "isPinned")
            }
        }
    }

    /// v3-v5: image clips, user titles, category ordering.
    private static func registerImageAndTitleMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-image-clips") { connection in
            try connection.alter(table: "clips") { tableBuilder in
                tableBuilder.add(column: "contentKind", .text).notNull().defaults(to: "text")
                tableBuilder.add(column: "mediaFilename", .text)
                tableBuilder.add(column: "thumbFilename", .text)
                tableBuilder.add(column: "pixelWidth", .integer)
                tableBuilder.add(column: "pixelHeight", .integer)
                tableBuilder.add(column: "byteSize", .integer)
            }
        }
        migrator.registerMigration("v4-user-titles") { connection in
            // Add the nullable userTitle column; existing rows stay NULL which
            // makes them fall back to sourceAppName in the UI (no data loss).
            try connection.alter(table: "clips") { tableBuilder in
                tableBuilder.add(column: "userTitle", .text)
            }
            // FTS5 synchronized tables cannot have columns added after creation,
            // so drop and recreate the virtual table to pick up userTitle.
            // GRDB's synchronize() creates three triggers on the content table;
            // they must be dropped explicitly before the FTS table is removed,
            // otherwise the subsequent CREATE VIRTUAL TABLE will try to create
            // them again and hit "trigger already exists".
            try connection.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_ai\"")
            try connection.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_ad\"")
            try connection.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_au\"")
            try connection.execute(sql: "DROP TABLE IF EXISTS clips_fts")
            try connection.create(virtualTable: "clips_fts", using: FTS5()) { tableBuilder in
                tableBuilder.synchronize(withTable: "clips")
                tableBuilder.tokenizer = .unicode61()
                tableBuilder.column("contentText")
                tableBuilder.column("userTitle")
            }
        }
        migrator.registerMigration("v5-clip-category-sort-order") { connection in
            // Add per-category clip ordering to the junction table. SQLite's
            // ALTER TABLE does not support NOT NULL without a default on
            // existing tables, so DEFAULT 0 is required here.
            try connection.execute(sql: """
                ALTER TABLE clip_category ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0
                """)
            // Backfill: within each category, assign sortOrder by addedAt DESC
            // so the most-recently-added clip appears first (matching the
            // pre-reorder visible order). Gap-free 0-based integers per category.
            try connection.execute(sql: """
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
            try connection.create(indexOn: "clip_category", columns: ["categoryID", "sortOrder"])
        }
    }

    /// v6-v8: file clips, unique category names, sort repair.
    private static func registerFileAndRepairMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-file-clips") { connection in
            // Add the nullable filePath column for file clips. Additive only;
            // existing text and image rows simply get NULL here.
            try connection.alter(table: "clips") { tableBuilder in
                tableBuilder.add(column: "filePath", .text)
            }
        }
        migrator.registerMigration("v7-category-name-unique") { connection in
            // Case-insensitive unique names (SBR-04). Existing duplicates are
            // renamed "Name 2", "Name 3", ... (oldest keeps the plain name) so
            // the index can be created without losing any category.
            let rows = try Row.fetchAll(connection, sql: "SELECT id, name FROM category ORDER BY createdAt, id")
            var used = Set<String>()
            for row in rows {
                let id: Int64 = row["id"]
                let name: String = row["name"]
                var candidate = name
                var suffix = 2
                while used.contains(candidate.lowercased()) {
                    candidate = "\(name) \(suffix)"
                    suffix += 1
                }
                used.insert(candidate.lowercased())
                if candidate != name {
                    try connection.execute(sql: "UPDATE category SET name = ? WHERE id = ?", arguments: [candidate, id])
                }
            }
            try connection.execute(sql: "CREATE UNIQUE INDEX category_name_nocase ON category (name COLLATE NOCASE)")
        }
        migrator.registerMigration("v8-clip-category-sort-repair") { connection in
            // The v5 backfill produced 0, -1, -2, ... (COUNT(*) collapsed to 1),
            // listing legacy categories oldest-first (SBR-07). Categories the user
            // has reordered since were renumbered gap-free from 0 by moveClip, so
            // only categories that still hold a negative sortOrder are repaired:
            // renumber them 0... by addedAt DESC.
            try connection.execute(sql: """
                UPDATE clip_category
                SET sortOrder = (
                    SELECT r.rn FROM (
                        SELECT clipID AS c, categoryID AS g,
                               ROW_NUMBER() OVER (
                                   PARTITION BY categoryID ORDER BY addedAt DESC, clipID DESC
                               ) - 1 AS rn
                        FROM clip_category
                    ) AS r
                    WHERE r.c = clip_category.clipID AND r.g = clip_category.categoryID
                )
                WHERE categoryID IN (SELECT categoryID FROM clip_category WHERE sortOrder < 0)
                """)
        }
    }

    /// v9-v10: OCR text and smart collections.
    private static func registerOcrAndCollectionMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9-ocr-text") { connection in
            // Recognised image text, searchable through clips_fts. NULL = never
            // scanned, "" = scanned and no text found. Additive column.
            try connection.alter(table: "clips") { tableBuilder in
                tableBuilder.add(column: "ocrText", .text)
            }
            // Same drop/recreate dance as v4: synchronized FTS5 tables cannot gain
            // columns. GRDB recreates the insert/update/delete triggers and
            // rebuilds the index from the clips table.
            try connection.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_ai\"")
            try connection.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_ad\"")
            try connection.execute(sql: "DROP TRIGGER IF EXISTS \"__clips_fts_au\"")
            try connection.execute(sql: "DROP TABLE IF EXISTS clips_fts")
            try connection.create(virtualTable: "clips_fts", using: FTS5()) { tableBuilder in
                tableBuilder.synchronize(withTable: "clips")
                tableBuilder.tokenizer = .unicode61()
                tableBuilder.column("contentText")
                tableBuilder.column("userTitle")
                tableBuilder.column("ocrText")
            }
        }
        migrator.registerMigration("v10-smart-collections") { connection in
            try connection.create(table: "smart_collections") { tableBuilder in
                tableBuilder.autoIncrementedPrimaryKey("id")
                tableBuilder.column("name", .text).notNull()
                tableBuilder.column("rule", .text).notNull()
                tableBuilder.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v11-perf-indexes") { connection in
            // Capture dedupe looks clips up by text; a 64-char prefix index keeps
            // that an index seek without storing every full text a second time.
            try connection.execute(sql: """
                CREATE INDEX IF NOT EXISTS clips_text_prefix
                ON clips (contentKind, substr(contentText, 1, 64))
                """)
            // Kind-only searches and the OCR image-existence probe need not scan
            // the full clips table; the tail matches their newest-first ordering.
            try connection.execute(sql: """
                CREATE INDEX IF NOT EXISTS clips_kind_created
                ON clips (contentKind, createdAt DESC, id DESC)
                """)
        }
    }
}
