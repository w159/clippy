import Foundation

/// Finder-style anchor + cursor selection over clip IDs (KEY-04).
///
/// The live selection is `committed` (items toggled in with Cmd-click, or the
/// whole set after Select All) plus the contiguous range between `anchor` and
/// `cursor`. Because the range is recomputed from the anchor on every extend,
/// Shift+arrow and Shift+click both grow AND shrink it. Pure value type; the
/// view republishes `published` after every operation.
struct RangeSelectionModel: Equatable {
    /// Fixed end of the live range.
    private(set) var anchor: Int64?
    /// Moving end of the live range; the keyboard-highlighted clip.
    private(set) var cursor: Int64?
    /// Selected clips outside the live range.
    private(set) var committed: Set<Int64> = []
    /// Full current selection.
    private(set) var selected: Set<Int64> = []

    /// True when the selection is empty or exactly the cursor clip: the view treats
    /// that as "no multi-selection" and highlights the cursor row instead. A lone
    /// selected clip that is NOT the cursor (Cmd-click deselected the rest) is not
    /// trivial, so it stays the actionable one.
    var isTrivial: Bool { selected.isEmpty || selected == cursor.map { [$0] } }

    /// The set the view publishes as its explicit multi-selection: empty when trivial.
    var published: Set<Int64> { isTrivial ? [] : selected }

    /// Plain click / plain arrow: collapse to a single clip.
    mutating func reset(to id: Int64?) {
        anchor = id
        cursor = id
        committed = []
        selected = id.map { [$0] } ?? []
    }

    /// Cmd-click: toggle one clip, keeping everything else. The previous live
    /// range is folded into the committed set first.
    mutating func toggle(_ id: Int64) {
        var next = selected
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        committed = next
        selected = next
        anchor = id
        cursor = id
    }

    /// Shift+arrow / Shift+click: move the cursor to `id` and select everything
    /// between the anchor and it (plus `committed`). Moving back toward the
    /// anchor shrinks the range.
    mutating func extend(to id: Int64, order: [Int64]) {
        guard let targetIndex = order.firstIndex(of: id) else { return }
        let fallback = cursor.flatMap { order.contains($0) ? $0 : nil } ?? id
        let anchorID = anchor.flatMap { order.contains($0) ? $0 : nil } ?? fallback
        anchor = anchorID
        guard let anchorIndex = order.firstIndex(of: anchorID) else { return }
        let lower = min(anchorIndex, targetIndex), upper = max(anchorIndex, targetIndex)
        selected = committed.union(order[lower...upper])
        cursor = id
    }

    /// Cmd+A over the visible clips. The cursor stays where it was when possible.
    mutating func selectAll(order: [Int64]) {
        let all = Set(order)
        let keep = cursor.flatMap { all.contains($0) ? $0 : nil } ?? order.first
        anchor = keep
        cursor = keep
        committed = all
        selected = all
    }

    /// Esc: drop the multi-selection but keep the cursor clip selected.
    mutating func collapseToCursor() { reset(to: cursor) }

    /// Forgets clips that no longer exist (DB pulse, delete).
    mutating func prune(keeping ids: Set<Int64>) {
        committed.formIntersection(ids)
        selected.formIntersection(ids)
        if let anchorID = anchor, !ids.contains(anchorID) { anchor = nil }
        if let cursorID = cursor, !ids.contains(cursorID) { cursor = nil }
    }

    /// Reconciles the model with what the view currently shows, for mutations that
    /// bypass the model (batch actions clearing the set, pane switches, reveals).
    mutating func adopt(published: Set<Int64>, cursor cursorID: Int64?) {
        if published.isEmpty {
            if cursorID != cursor || !isTrivial || selected != (cursorID.map { [$0] } ?? []) { reset(to: cursorID) }
        } else if published != self.published {
            committed = published
            selected = published
            anchor = cursorID
            cursor = cursorID
        }
    }

    /// The selection in list order.
    func ordered(in order: [Int64]) -> [Int64] { order.filter(selected.contains) }
}
