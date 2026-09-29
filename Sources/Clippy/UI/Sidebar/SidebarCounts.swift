import Foundation

/// Badge counts for the sidebar. The History count must equal what the History
/// pane displays (SBR-03): unpinned (unfiled) clips only.
struct SidebarCounts: Equatable {
    /// Clips shown in the History pane.
    var historyCount: Int

    /// Counts clips the History pane would show: those with no category membership.
    static func displayedHistoryCount(clipIDs: [Int64?], membership: [Int64: Set<Int64>]) -> Int {
        clipIDs.filter { id in id.map { (membership[$0] ?? []).isEmpty } ?? true }.count
    }

    /// Resolves the History count from a store, mirroring `ClipListView.clips(for: .history)`.
    @MainActor
    static func displayedHistoryCount(store: ClipStore) -> Int {
        displayedHistoryCount(clipIDs: store.clips.map(\.id), membership: store.membership)
    }
}
