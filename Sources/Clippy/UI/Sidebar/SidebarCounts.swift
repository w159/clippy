import Foundation

/// Badge counts for the sidebar. The History count must equal what the History
/// pane displays (SBR-03): unfiled clips while browsing, every match (filed
/// included) while searching, per `HistoryPanePolicy`.
struct SidebarCounts: Equatable {
    /// Clips shown in the History pane.
    var historyCount: Int

    /// Counts clips the History pane would show: those with no category membership,
    /// or all of them (they are already the matches) while `query` is a search.
    static func displayedHistoryCount(clipIDs: [Int64?], membership: [Int64: Set<Int64>], query: String = "") -> Int {
        if HistoryPanePolicy.isSearching(query) { return clipIDs.count }
        return clipIDs.filter { id in id.map { (membership[$0] ?? []).isEmpty } ?? true }.count
    }

    /// Counts what a category pane displays: every member while browsing, only the
    /// members matching `query` while searching (`ClipStore.clipsForCategory`).
    static func displayedCategoryCount(total: Int, query: String, matching: () -> Int) -> Int {
        HistoryPanePolicy.isSearching(query) ? matching() : total
    }

    /// Resolves a category's count from a store, mirroring `ClipListView.clips(for: .category)`.
    @MainActor
    static func displayedCategoryCount(store: ClipStore, categoryID: Int64) -> Int {
        displayedCategoryCount(total: store.clipCount(inCategory: categoryID), query: store.query,
                               matching: { store.clipsForCategory(categoryID).count })
    }

    /// Resolves the History count from a store, mirroring `ClipListView.clips(for: .history)`.
    @MainActor
    static func displayedHistoryCount(store: ClipStore) -> Int {
        displayedHistoryCount(clipIDs: store.clips.map(\.id), membership: store.membership, query: store.query)
    }
}
