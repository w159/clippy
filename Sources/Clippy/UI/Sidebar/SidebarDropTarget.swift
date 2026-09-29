import Foundation

/// The row a sidebar drop lands on.
enum SidebarDropRow: Equatable {
    /// The History home row (dropping clips here unfiles them).
    case history
    /// A category row.
    case category(Int64)
    /// The zone after the last category (reorder-to-end target).
    case trailing
}

/// Visual feedback for a drag hovering a sidebar row (SBR-05). Filing and
/// reordering deliberately look different: a ring vs. a line.
enum SidebarDropIndicator: Equatable {
    /// No drag feedback.
    case none
    /// Accent inset ring: "file the dragged clips into this category".
    case fileRing
    /// Accent inset ring on History: "unfile the dragged clips".
    case unfileRing
    /// 2pt insertion line: "move the dragged category here".
    case reorderLine
}

/// The store mutation a completed sidebar drop should perform.
enum SidebarDropAction: Equatable {
    /// File every clip into the category.
    case fileClips([Int64], into: Int64)
    /// Remove every clip from all categories.
    case unfileClips([Int64])
    /// Move category `id` immediately before `before` (`Int64.max` = end).
    case reorderCategory(id: Int64, before: Int64)
    /// Nothing to do; the drop is rejected.
    case ignore
}

/// Pure classification of sidebar drags, unit-tested without any view.
enum SidebarDropTarget {
    /// Sentinel "before" id that makes `moveCategory` append at the end.
    static let endSentinel: Int64 = .max

    /// Indicator for a hover. `isCategoryDrag` is true when the dragged item is
    /// a category row rather than clips.
    static func indicator(isCategoryDrag: Bool, over row: SidebarDropRow) -> SidebarDropIndicator {
        switch (isCategoryDrag, row) {
        case (true, .history): return .none
        case (true, _): return .reorderLine
        case (false, .history): return .unfileRing
        case (false, .category): return .fileRing
        case (false, .trailing): return .none
        }
    }

    /// Resolves dropped string payloads (`clip:<id>`, `reorder:clip:<id>`,
    /// `reorder:cat:<id>`) to an action. Multi-item clip drops file all clips.
    static func action(for payloads: [String], on row: SidebarDropRow) -> SidebarDropAction {
        var clipIDs: [Int64] = []
        var draggedCategory: Int64?
        for payload in payloads {
            switch routeCategoryRowDrop(payload) {
            case .fileClip(let clipID): if !clipIDs.contains(clipID) { clipIDs.append(clipID) }
            case .reorderCategory(let categoryID): draggedCategory = draggedCategory ?? categoryID
            case .ignore: continue
            }
        }
        switch row {
        case .history:
            return clipIDs.isEmpty ? .ignore : .unfileClips(clipIDs)
        case .category(let target):
            if let dragged = draggedCategory {
                return dragged == target ? .ignore : .reorderCategory(id: dragged, before: target)
            }
            return clipIDs.isEmpty ? .ignore : .fileClips(clipIDs, into: target)
        case .trailing:
            return draggedCategory.map { .reorderCategory(id: $0, before: endSentinel) } ?? .ignore
        }
    }
}
