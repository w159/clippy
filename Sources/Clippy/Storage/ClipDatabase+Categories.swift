import Foundation
import GRDB

// MARK: - Categories

extension ClipDatabase {
    func categories() throws -> [Category] {
        try dbQueue.read { db in
            try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        }
    }

    func starterCategory() throws -> Category? {
        try dbQueue.read { db in
            try Category.filter(Column("isStarter") == true).fetchOne(db)
        }
    }

    /// Cached after first lookup: the starter category is created in migration
    /// v2 and never deleted, so its id is stable for the process lifetime.
    func starterCategoryID() throws -> Int64? {
        if let cachedStarterCategoryID { return cachedStarterCategoryID }
        cachedStarterCategoryID = try starterCategory()?.id
        return cachedStarterCategoryID
    }

    @discardableResult
    func createCategory(
        named name: String,
        colorHex: String,
        iconKind: CategoryIconKind,
        iconValue: String
    ) throws -> Category {
        try dbQueue.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortOrder), -1) FROM category") ?? -1
            var category = Category(
                id: nil,
                name: name,
                colorHex: colorHex,
                iconKind: iconKind,
                iconValue: iconValue,
                sortOrder: maxOrder + 1,
                isStarter: false,
                createdAt: Date()
            )
            try category.insert(db)
            return category
        }
    }

    func updateCategory(_ category: Category) throws {
        try dbQueue.write { db in
            try category.update(db)
        }
    }

    func deleteCategory(id: Int64) throws {
        // Audit finding: recreating the starter after deletion loses its custom
        // name/color/icon. Snapshot the starter's attributes BEFORE the row is
        // removed so ensureStarterCategoryID can restore them instead of falling
        // back to the hardcoded "Pinned"/#FF9500/pin.fill defaults.
        if id == cachedStarterCategoryID || cachedStarterCategoryID == nil {
            // try? flattens the optional from fetchOne, so doomed is non-optional
            // Category when a matching row exists.
            if let doomed = try? dbQueue.read({ db in
                try Category.filter(Column("id") == id).fetchOne(db)
            }), doomed.isStarter == true {
                StarterSnapshot.last = StarterSnapshot(
                    name: doomed.name, colorHex: doomed.colorHex,
                    iconKind: doomed.iconKind, iconValue: doomed.iconValue)
            }
        }
        _ = try dbQueue.write { db in
            try Category.deleteOne(db, key: id)
        }
        // Drop the cache if the starter itself was deleted so Cmd+P recreates it.
        if id == cachedStarterCategoryID { cachedStarterCategoryID = nil }
    }

    /// Reorder: place `id` immediately before `targetID`, then renumber every
    /// category's sortOrder sequentially so the order is stable and gap-free.
    func moveCategory(id: Int64, before targetID: Int64) throws {
        try dbQueue.write { db in
            let cats = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
            let ids = cats.map { $0.id! }
            // Delegate ordering computation to the pure function; wrap the
            // non-optional targetID so the signature matches.
            let newIDs = reorderIDs(ids, draggedID: id, before: targetID)
            // Build a lookup so we can avoid a linear scan per row.
            let catByID = Dictionary(uniqueKeysWithValues: cats.compactMap { c in c.id.map { ($0, c) } })
            for (index, catID) in newIDs.enumerated() {
                guard var updated = catByID[catID], updated.sortOrder != index else { continue }
                updated.sortOrder = index
                try updated.update(db)
            }
        }
    }

    /// Recreate the starter ("Pinned") category if the user deleted it, so the
    /// Cmd+P pin shortcut always has a home to toggle.
    ///
    /// Audit finding: the previous recreation always clobbered the starter with
    /// hardcoded "Pinned"/#FF9500/pin.fill, so a renamed/recolored starter lost
    /// its customization after delete + Cmd+P. If a snapshot was captured at
    /// delete time, restore those attributes. A starter row that still exists is
    /// returned untouched (no clobber), which already held before this change.
    private func ensureStarterCategoryID() throws -> Int64? {
        if let id = try starterCategoryID() { return id }
        let snap = StarterSnapshot.last
        let created = try dbQueue.write { db -> Int64? in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortOrder), -1) FROM category") ?? -1
            var category = Category(
                id: nil,
                name: snap?.name ?? "Pinned",
                colorHex: snap?.colorHex ?? "#FF9500",
                iconKind: snap?.iconKind ?? .symbol,
                iconValue: snap?.iconValue ?? "pin.fill",
                sortOrder: maxOrder + 1, isStarter: true, createdAt: Date()
            )
            try category.insert(db)
            return category.id
        }
        cachedStarterCategoryID = created
        return created
    }

    func setClip(_ clipID: Int64, inCategory categoryID: Int64, _ isMember: Bool) throws {
        try dbQueue.write { db in
            if isMember {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)",
                    arguments: [clipID, categoryID, Date()]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?",
                    arguments: [clipID, categoryID]
                )
            }
        }
    }

    /// Cmd+P fast path: one keystroke toggles membership in the starter category.
    func toggleStarterMembership(clipID: Int64) throws {
        guard let starterID = try ensureStarterCategoryID() else { return }
        try dbQueue.write { db in
            let isMember = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM clip_category WHERE clipID = ? AND categoryID = ?)",
                arguments: [clipID, starterID]
            ) ?? false
            if isMember {
                try db.execute(
                    sql: "DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?",
                    arguments: [clipID, starterID]
                )
            } else {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)",
                    arguments: [clipID, starterID, Date()]
                )
            }
        }
    }

    /// Clips belonging to a category, ordered by their per-category sortOrder.
    /// Used to drive the reorderable clip list in a category pane.
    func clipsForCategory(_ categoryID: Int64) throws -> [Clip] {
        try dbQueue.read { db in
            try Clip.fetchAll(
                db,
                sql: """
                    SELECT clips.*
                    FROM clips
                    JOIN clip_category ON clip_category.clipID = clips.id
                    WHERE clip_category.categoryID = ?
                    ORDER BY clip_category.sortOrder ASC, clip_category.addedAt DESC
                    """,
                arguments: [categoryID]
            )
        }
    }

    /// Reorder: place `clipID` immediately before `targetClipID` within
    /// `categoryID`, then renumber that category's sortOrder gap-free.
    /// Pass nil for `targetClipID` to move `clipID` to the end of the list.
    func moveClip(_ clipID: Int64, inCategory categoryID: Int64, before targetClipID: Int64?) throws {
        try dbQueue.write { db in
            // Load the current ordered clip IDs for this category.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT clipID FROM clip_category
                    WHERE categoryID = ?
                    ORDER BY sortOrder ASC, addedAt DESC
                    """,
                arguments: [categoryID]
            )
            let ids: [Int64] = rows.map { $0["clipID"] }
            // Guard mirrors the original: skip entirely if clipID is not a member.
            // reorderIDs returns ids unchanged in that case.
            guard ids.contains(clipID) else { return }
            let newIDs = reorderIDs(ids, draggedID: clipID, before: targetClipID)
            // Audit finding: this loop previously wrote every sortOrder row
            // unconditionally, so a single-clip move issued N UPDATEs. Mirror
            // moveCategory's guard: skip rows whose current order already equals
            // the target order. `ids` is ordered by current sortOrder, so its
            // index IS the current order of each id.
            let currentOrder = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            for (order, id) in newIDs.enumerated() {
                guard currentOrder[id] != order else { continue }
                try db.execute(
                    sql: """
                        UPDATE clip_category SET sortOrder = ?
                        WHERE clipID = ? AND categoryID = ?
                        """,
                    arguments: [order, id, categoryID]
                )
            }
        }
    }

    /// clipID -> set of category IDs, for fast pinned/membership lookups in views.
    // Whole-table load is bounded in practice: uncategorized clips are capped
    // and categorized clips are user-curated.
    func membershipMap() throws -> [Int64: Set<Int64>] {
        try dbQueue.read { try Self.buildMembershipMap($0) }
    }

    /// The single clipID -> categoryID fold. `static` so the `ValueObservation`
    /// closure in ClipStore can call it without capturing a `ClipDatabase`.
    static func buildMembershipMap(_ db: Database) throws -> [Int64: Set<Int64>] {
        let rows = try Row.fetchAll(db, sql: "SELECT clipID, categoryID FROM clip_category")
        var map: [Int64: Set<Int64>] = [:]
        for row in rows {
            map[row["clipID"], default: []].insert(row["categoryID"])
        }
        return map
    }
}

// MARK: - Starter category snapshot
//
// Process-lifetime cache of the starter category's last-known attributes, so
// delete + Cmd+P recreate restores the user's name/color/icon instead of the
// hardcoded defaults. Held as a file-private var; nil means "no snapshot."
private struct StarterSnapshot {
    let name: String
    let colorHex: String
    let iconKind: CategoryIconKind
    let iconValue: String
    fileprivate static var last: StarterSnapshot?
}
