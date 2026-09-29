import AppKit
import SwiftUI

extension CategorySidePane {
    /// Rows in visual order, for arrow-key navigation.
    var orderedRows: [SidebarRowID] {
        var rows: [SidebarRowID] = isOpen(.library) ? [.history] : []
        if isOpen(.categories) { rows += store.categories.compactMap { $0.id.map { SidebarRowID.category($0) } } }
        if isOpen(.tools) { rows += SidebarTool.visible(onePassword: settings.onePasswordEnabled, suggestions: settings.suggestionsEnabled, ai: settings.aiEnabled).map(\.rowID) }
        rows.append(.newCategory)
        return rows
    }

    // MARK: - Keyboard

    /// Arrows move, Return/Space activate, F2 renames, Delete confirms, Cmd+Z undoes.
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard renamingID == nil else { return .ignored }
        if press.characters == "\u{F705}" {
            guard case .category(let categoryID)? = focus, let category = store.categories.first(where: { $0.id == categoryID }) else { return .ignored }
            beginRename(category)
            return .handled
        }
        switch press.key {
        case .upArrow: focus = SidebarNavigation.step(in: orderedRows, from: focus, delta: -1)
        case .downArrow: focus = SidebarNavigation.step(in: orderedRows, from: focus, delta: 1)
        case .return: guard let row = focus else { return .ignored }; activate(row)
        case .delete, .deleteForward:
            guard case .category(let categoryID)? = focus, let category = store.categories.first(where: { $0.id == categoryID }) else { return .ignored }
            categoryToDelete = category
        default: return .ignored
        }
        return .handled
    }

    func activate(_ row: SidebarRowID) {
        switch row {
        case .history: selection = .history
        case .category(let categoryID): selection = selection == .category(categoryID) ? .history : .category(categoryID)
        case .newCategory: isCreating = true
        default:
            if let tool = SidebarTool.allCases.first(where: { $0.rowID == row }) { selection = selection == tool.selection ? .history : tool.selection }
        }
    }

    // MARK: - Rename

    func beginRename(_ category: Category) {
        renameDraft = category.name
        renameDuplicate = false
        renamingID = category.id
    }

    func cancelRename() {
        let restore = renamingID
        renamingID = nil
        renameDuplicate = false
        if let restore { focus = .category(restore) }
    }

    func commitRename(_ category: Category) {
        guard renamingID == category.id else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == category.name { cancelRename(); return }
        if store.existingCategoryNames(excluding: category).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            renameDuplicate = true
            return
        }
        var updated = category
        updated.name = name
        store.updateCategory(updated)
        cancelRename()
    }

    // MARK: - Delete

    func confirmDelete() {
        guard let category = categoryToDelete, let categoryID = category.id else { categoryToDelete = nil; return }
        let members = store.membership.filter { $0.value.contains(categoryID) }.keys.sorted()
        undo.recordDelete(category, orderBefore: store.categories.compactMap(\.id), members: members)
        if selection == .category(categoryID) { selection = .history }
        store.deleteCategory(category)
        categoryToDelete = nil
    }

    // MARK: - Drops

    /// Executes a classified drop; returns whether it was accepted.
    func performDrop(_ action: SidebarDropAction) -> Bool {
        dragState.end()
        switch action {
        case .ignore:
            return false
        case .fileClips(let clipIDs, let categoryID):
            for clipID in clipIDs { store.fileClip(id: clipID, intoCategory: categoryID) }
        case .unfileClips(let clipIDs):
            for clipID in clipIDs {
                guard let clip = store.recentsByID[clipID] else { continue }
                for categoryID in store.categoryIDs(for: clip) { store.setClip(clip, inCategory: categoryID, false) }
            }
        case .reorderCategory(let draggedID, let targetID):
            undo.recordReorder(orderBefore: store.categories.compactMap(\.id))
            store.moveCategory(id: draggedID, beforeCategoryID: targetID)
        }
        return true
    }
}
