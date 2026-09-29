import Foundation
import GRDB

extension ClipStore {
    // MARK: - Category CRUD

    /// Category names for the editor's `existingNames` duplicate check
    /// (SBR-04). Pass `excluding` when renaming so a category does not collide
    /// with itself.
    func existingCategoryNames(excluding category: Category? = nil) -> [String] {
        categories.filter { $0.id != category?.id || category?.id == nil }.map(\.name)
    }

    /// Create a category, throwing `CategoryError` (empty/duplicate name) or the
    /// underlying database error (DAT-14).
    @discardableResult
    func tryCreateCategory(
        named name: String, colorHex: String, iconKind: CategoryIconKind, iconValue: String
    ) throws -> Category {
        try database.createCategory(
            named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
    }

    func tryUpdateCategory(_ category: Category) throws {
        try database.updateCategory(category)
    }

    func tryDeleteCategory(_ category: Category) throws {
        guard let id = category.id else { return }
        try database.deleteCategory(id: id)
    }

    /// Non-throwing wrapper kept for existing callers: failures are logged and
    /// published on `categoryError` instead of being swallowed.
    @discardableResult
    func createCategory(
        named name: String, colorHex: String, iconKind: CategoryIconKind, iconValue: String
    ) -> Category? {
        surface("createCategory") {
            try tryCreateCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
        }
    }

    func updateCategory(_ category: Category) {
        surface("updateCategory") { try tryUpdateCategory(category) }
    }

    func deleteCategory(_ category: Category) {
        surface("deleteCategory") { try tryDeleteCategory(category) }
    }

    /// Runs `body`, publishing any failure on `categoryError`.
    private func surface<T>(_ label: String, _ body: () throws -> T) -> T? {
        do {
            categoryError = nil
            return try body()
        } catch {
            ClippyLog.error("\(label) failed: \(error)", category: ClippyLog.storage)
            categoryError = error.localizedDescription
            return nil
        }
    }

    /// Move one category so it sits just before another (drag-to-reorder).
    func moveCategory(id: Int64, beforeCategoryID: Int64) {
        performWrite("moveCategory") { [database] in
            try database.moveCategory(id: id, before: beforeCategoryID)
        }
    }

    /// Clips for a category in user-defined sortOrder. Uses the categoryClipOrder
    /// map so the result is instantly consistent with the live observation.
    /// When a search query is active, the result is further filtered in-memory
    /// so the search bar scopes to the pane the user is viewing.
    func clipsForCategory(_ categoryID: Int64) -> [Clip] {
        // Source from `recents` (every categorized clip, unconditionally) rather
        // than `clips` (overwritten by FTS search results): otherwise an active
        // global search query makes category members that do not match the query
        // vanish from their own category pane.
        let ordered: [Clip]
        if let orderedIDs = categoryClipOrder[categoryID] {
            ordered = orderedIDs.compactMap { recentsByID[$0] }
        } else {
            ordered = recents.filter { membership[$0.id ?? -1]?.contains(categoryID) == true }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { $0.matchesLocally(query: trimmed) }
    }

    /// Move a clip to a new position within a category (drag-to-reorder).
    /// `targetClipID` is the clip the dragged one is dropped onto; pass nil to
    /// move to the end of the list.
    func moveClip(_ clipID: Int64, inCategory categoryID: Int64, before targetClipID: Int64?) {
        // Optimistic: republish the reordered ids immediately so the drop
        // animates without waiting on the DB write. The observation pulse that
        // follows the write recomputes the identical order (same reorderIDs
        // applied to the same list), so no visible correction occurs.
        if let current = categoryClipOrder[categoryID], current.contains(clipID) {
            categoryClipOrder[categoryID] = reorderIDs(
                current, draggedID: clipID, before: targetClipID)
        }
        performWrite("moveClip") { [database] in
            try database.moveClip(clipID, inCategory: categoryID, before: targetClipID)
        }
    }


    // MARK: - Derived data

    /// Distinct source apps seen in history, for category icon pickers.
    var knownBundleIDs: [String] {
        var seen = Set<String>()
        return clips.compactMap(\.sourceAppBundleID).filter { seen.insert($0).inserted }
    }

    // MARK: - Membership queries

    func isPinned(_ clip: Clip) -> Bool {
        guard let id = clip.id else { return false }
        return !(membership[id] ?? []).isEmpty
    }

    func categoryIDs(for clip: Clip) -> Set<Int64> {
        guard let id = clip.id else { return [] }
        return membership[id] ?? []
    }

    func clipCount(inCategory categoryID: Int64) -> Int {
        membership.values.reduce(0) { $0 + ($1.contains(categoryID) ? 1 : 0) }
    }
}
