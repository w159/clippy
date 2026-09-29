import Combine
import Foundation

/// Store operations `CategoryUndo` needs; a fake conforms in tests.
protocol CategoryUndoBackend: AnyObject {
    /// Recreates a deleted category (new id, same name/color/icon); nil on failure.
    func recreate(_ category: Category) -> Category?
    /// Adds or removes a clip's membership.
    func setMember(clipID: Int64, categoryID: Int64, isMember: Bool)
    /// Moves a category immediately before another (`Int64.max` appends).
    func move(categoryID: Int64, before targetID: Int64)
}

/// Undo stack for sidebar category delete and reorder (SBR-06). Categories are
/// not clips, so this is separate from `ClipUndoBuffer`.
@MainActor
final class CategoryUndo: ObservableObject {
    /// One undoable category change.
    enum Entry: Equatable {
        /// A category was deleted: its record, the full order before deletion, and member clips.
        case deleted(Category, orderBefore: [Int64], members: [Int64])
        /// Categories were reordered from `orderBefore`.
        case reordered(orderBefore: [Int64])
    }

    /// Most recent last.
    @Published private(set) var entries: [Entry] = []
    private let backend: CategoryUndoBackend
    /// Optional window undo manager; set once the view appears.
    var undoManager: UndoManager?
    private let limit = 20

    /// Creates an undo stack; entries are also registered with `undoManager` when given.
    init(backend: CategoryUndoBackend, undoManager: UndoManager? = nil) {
        self.backend = backend
        self.undoManager = undoManager
    }

    /// True when there is something to undo.
    var canUndo: Bool { !entries.isEmpty }

    /// Records a deletion made from `orderBefore` (which includes the deleted id).
    func recordDelete(_ category: Category, orderBefore: [Int64], members: [Int64]) {
        push(.deleted(category, orderBefore: orderBefore, members: members), name: "Delete Category")
    }

    /// Records a reorder from `orderBefore`.
    func recordReorder(orderBefore: [Int64]) {
        push(.reordered(orderBefore: orderBefore), name: "Reorder Categories")
    }

    /// Reverts the most recent change. Returns false when the stack is empty or restore failed.
    @discardableResult
    func undo() -> Bool {
        guard let entry = entries.popLast() else { return false }
        switch entry {
        case .reordered(let order):
            apply(order: order)
            return true
        case .deleted(let category, let order, let members):
            guard let restored = backend.recreate(category), let newID = restored.id else { return false }
            for clipID in members { backend.setMember(clipID: clipID, categoryID: newID, isMember: true) }
            apply(order: Self.replacing(oldID: category.id, with: newID, in: order))
            return true
        }
    }

    /// Order with `oldID` swapped for `newID`.
    static func replacing(oldID: Int64?, with newID: Int64, in order: [Int64]) -> [Int64] {
        order.map { $0 == oldID ? newID : $0 }
    }

    /// Reproduces `order` by appending each id in sequence.
    private func apply(order: [Int64]) {
        for id in order { backend.move(categoryID: id, before: SidebarDropTarget.endSentinel) }
    }

    private func push(_ entry: Entry, name: String) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
        undoManager?.setActionName(name)
    }
}

/// Production backend over `ClipStore`'s category APIs.
@MainActor
final class ClipStoreCategoryBackend: @MainActor CategoryUndoBackend {
    private unowned let store: ClipStore

    /// Wraps `store`.
    init(store: ClipStore) { self.store = store }

    func recreate(_ category: Category) -> Category? {
        store.createCategory(
            named: category.name, colorHex: category.colorHex, iconKind: category.iconKind, iconValue: category.iconValue)
    }

    func setMember(clipID: Int64, categoryID: Int64, isMember: Bool) {
        if isMember { store.addClip(id: clipID, toCategory: categoryID) } else if let clip = store.recentsByID[clipID] {
            store.setClip(clip, inCategory: categoryID, false)
        }
    }

    func move(categoryID: Int64, before targetID: Int64) {
        store.moveCategory(id: categoryID, beforeCategoryID: targetID)
    }
}
