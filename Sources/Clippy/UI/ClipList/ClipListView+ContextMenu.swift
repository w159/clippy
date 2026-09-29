import SwiftUI
import AppKit

// Context-menu content for `ClipListView`: the AI actions submenu and its
// items, plus the categories submenu.

extension ClipListView {
    // MARK: - AI actions context submenu

    @ViewBuilder
    func aiActionsMenu(for clip: Clip) -> some View {
        if !settings.aiEnabled {
            Menu {
                Text("Enable AI in Settings to use AI actions.")
            } label: {
                Label("AI", systemImage: "sparkles")
            }
        } else {
            Menu {
                aiMenuItems(for: clip)
            } label: {
                Label("AI", systemImage: "sparkles")
            }
        }
    }

    /// The AI menu body, shared between the context-menu "AI" submenu and the
    /// clip card's hover sparkles menu so both dispatch through the same paths.
    @ViewBuilder
    func aiMenuItems(for clip: Clip) -> some View {
        let actions = AIActionStore.shared.actions
        ForEach(actions) { action in
            Button {
                runAIAction(action, on: clip)
            } label: {
                // Use ActionIconView so emoji/appLogo icons render correctly.
                // SwiftUI menus accept any label content, not just Label().
                HStack {
                    ActionIconView(kind: action.iconKind, value: action.symbolName)
                    Text(action.name)
                }
            }
        }
        if actions.isEmpty {
            Text("No actions configured.")
        }
        Divider()
        Button("Open AI Assistant") { openAssistant(with: clip) }
    }

    func categoriesMenu(for clip: Clip) -> some View {
        Menu {
            ForEach(store.categories) { category in
                let categoryID = category.id ?? -1
                let isMember = store.categoryIDs(for: clip).contains(categoryID)
                Button {
                    if isMember {
                        // Tapping a member category removes the clip from it.
                        store.setClip(clip, inCategory: categoryID, false)
                    } else if let clipID = clip.id {
                        // Filing routes through fileClip so single-membership mode
                        // clears the other categories; multiple-mode stays additive.
                        store.fileClip(id: clipID, intoCategory: categoryID)
                    }
                } label: {
                    if isMember {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
            Divider()
            Button("New Category...") { categoryCreationClip = clip }
        } label: {
            Label("Categories", systemImage: "folder.badge.plus")
        }
    }

    /// Context menu for a card: batch actions when 2+ clips are selected,
    /// otherwise the single-clip menu.
    @ViewBuilder
    func cardContextMenu(for clip: Clip) -> some View {
        if ContextMenuScope.resolve(clickedID: clip.id, multiSelection: selectedClipIDs) == .batch {
            batchContextMenu()
        } else {
            singleClipContextMenu(for: clip)
        }
    }

    /// Batch variants act on the whole multi-selection.
    @ViewBuilder
    func batchContextMenu() -> some View {
        Button("Paste \(selectedClipIDs.count) Sequentially") { onPasteMany(actionableClips, false, settings.pastePlainTextByDefault) }
        Button("Paste \(selectedClipIDs.count) Combined") { onPasteMany(actionableClips, true, settings.pastePlainTextByDefault) }
        Menu("Move \(selectedClipIDs.count) to Category") {
            ForEach(store.categories) { cat in
                Button(cat.name) {
                    for clip in actionableClips { if let id = clip.id, let cid = cat.id { store.fileClip(id: id, intoCategory: cid) } }
                    selectedClipIDs = []
                }
            }
        }
        batchFeatureMenuItems()
        if let activeCategoryID = activeCategoryID {
            Button("Remove \(selectedClipIDs.count) from Category") {
                for clip in actionableClips { store.setClip(clip, inCategory: activeCategoryID, false) }
                selectedClipIDs = []
            }
        }
        Button("Set \(selectedClipIDs.count) Titles with AI") { runBatchAITitles() }
        Divider()
        Button("Delete \(selectedClipIDs.count)", role: .destructive) { requestBatchDelete() }
    }

    /// Menu for a single clip, grouped: paste, edit, organize, AI/analysis, delete.
    @ViewBuilder
    func singleClipContextMenu(for clip: Clip) -> some View {
        // Paste group
        Button { onPaste(clip, false) } label: { Label("Paste", systemImage: "arrow.down.doc") }
        if clip.contentKind == .text {
            Button { onPaste(clip, true) } label: { Label("Paste as Plain Text", systemImage: "textformat") }
        }
        if clip.contentKind == .file {
            Button { onPasteFile(clip, true) } label: { Label("Move Here (removes original)", systemImage: "folder") }
        }
        Divider()
        // Edit group
        if clip.contentKind == .text {
            Button { onEdit(clip) } label: { Label("Edit\u{2026}", systemImage: "pencil") }
            Button {
                ExternalEditorService.shared.edit(clip: clip, store: store)
            } label: { Label(ExternalEditorService.shared.menuTitle, systemImage: "square.and.pencil") }
        }
        Button { renamingClipID = clip.id } label: { Label("Rename\u{2026}", systemImage: "character.cursor.ibeam") }
        if clip.isImageLike {
            Button { runOCR(on: clip) } label: { Label("Extract Text", systemImage: "text.viewfinder") }
        }
        Divider()
        // Organize group
        Button { store.togglePin(clip) } label: {
            Label(store.isPinned(clip) ? "Unpin" : "Pin", systemImage: store.isPinned(clip) ? "pin.slash" : "pin")
        }
        categoriesMenu(for: clip)
        // KEY-10: already in the History timeline (no query) there is nowhere to jump.
        if !(selection == .history && store.query.isEmpty) {
            Button { revealInTimeline(clip) } label: { Label("Show in Timeline", systemImage: "clock.arrow.circlepath") }
        }
        if clip.contentKind == .text {
            Divider()
            aiActionsMenu(for: clip)
            if settings.suggestionsEnabled {
                Button {
                    store.findSimilar(to: clip)
                    selection = .suggestions
                } label: { Label("Find Similar Clips", systemImage: "sparkle.magnifyingglass") }
            }
        }
        featureMenuItems(for: clip)
        Divider()
        Button(role: .destructive) { requestDelete(clip) } label: { Label("Delete", systemImage: "trash") }
    }
}
