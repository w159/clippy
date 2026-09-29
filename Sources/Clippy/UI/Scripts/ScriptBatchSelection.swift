import Foundation

/// Selection model for the script list: single open script plus multi-select for
/// batch runs. Order is the list's visible order, so a batch runs top to bottom.
struct ScriptBatchSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    /// Anchor for shift-range selection (the last plainly clicked row).
    private(set) var anchor: UUID?

    init(ids: Set<UUID> = [], anchor: UUID? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    var count: Int { ids.count }

    /// True when the batch bar should show (two or more rows chosen).
    var isBatch: Bool { ids.count > 1 }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Plain click: selects only `id` and makes it the anchor.
    mutating func select(_ id: UUID) {
        ids = [id]
        anchor = id
    }

    /// Command-click: adds or removes one row; keeps the anchor on the last added row.
    mutating func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// Shift-click: selects the inclusive range between the anchor and `id` in `visible` order.
    mutating func extend(to id: UUID, in visible: [UUID]) {
        guard let anchor, let from = visible.firstIndex(of: anchor), let to = visible.firstIndex(of: id) else {
            select(id)
            return
        }
        ids = Set(visible[min(from, to)...max(from, to)])
    }

    mutating func selectAll(_ visible: [UUID]) {
        ids = Set(visible)
        anchor = visible.first
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// Drops ids that no longer exist (after delete or filter change).
    mutating func prune(keeping existing: [UUID]) {
        ids.formIntersection(existing)
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
    }

    /// The selected ids in list order, which is the batch run order.
    func ordered(in visible: [UUID]) -> [UUID] { visible.filter { ids.contains($0) } }
}
