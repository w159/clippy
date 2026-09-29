import SwiftUI
import AppKit

// Row assembly for `ClipListView`: the end-of-list drop zone and the
// `card(for:at:metadata:)` builder with its gestures and callbacks.

extension ClipListView {
    /// Full-width drop target placed after the last clip in a category pane so a
    /// clip reorder drag can land past the end. `moveClip(before: nil)` appends.
    func trailingClipDropZone(inCategory categoryID: Int64) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .reorderTrailingDropDestination(kind: "clip", isTargeted: $draggingOverTrailingClip) { draggedID in
                store.moveClip(draggedID, inCategory: categoryID, before: nil)
            }
            .accessibilityHidden(true)
    }

    /// Builds one history row. Modifier order is load-bearing: the high-priority
    /// double-tap and the simultaneous single-tap sit after the reorder modifier
    /// that owns the only `.draggable`.
    func card(for clip: Clip, at index: Int, metadata: [Int64: CardMetadata]) -> some View {
        let clipID = clip.id ?? -1
        let categoryID = activeCategoryID
        return cardBody(for: clip, at: index, metadata: metadata)
        // Drag payload is managed entirely by CategoryReorderModifier so that
        // only one .draggable is ever applied to this view. Two stacked
        // .draggable modifiers on the same view cause SwiftUI to use only the
        // inner one, silently dropping the outer reorder token.
        .modifier(CategoryReorderModifier(
            clipID: clipID,
            categoryID: categoryID,
            store: store,
            item: dragItem(for: clip, categoryID: categoryID)
        ))
        // Tap gestures are attached via .simultaneousGesture so they process at
        // the SAME priority as, and concurrently with, the .draggable's own drag
        // gesture instead of competing for recognition. A plain .onTapGesture is
        // a normal-precedence gesture that competes with the view's gestures, and
        // on macOS its mouse-down often claims the press before the drag can
        // begin, so the drag never starts. .simultaneousGesture lets the tap and
        // the drag both be recognized: a click-without-move fires the tap, a
        // press-and-move starts the drag.
        //   Apple docs, "Composing SwiftUI gestures" + simultaneousGesture(_:):
        //   "they all execute when triggered, rather than competing for
        //   recognition ... without one preventing the other from executing."
        //   (developer.apple.com/documentation/swiftui/composing-swiftui-gestures)
        // highPriorityGesture is used ONLY for the double-tap so SwiftUI waits
        // for the double-click timeout before the count:1 tap commits, which
        // stops the single-tap from firing on both clicks of a double-click
        // (audit: single-tap fires on both clicks of a double-click paste). It
        // is NOT applied to the count:1 tap: that stays .simultaneousGesture so
        // the drag (which needs the press-and-move path) still coexists with
        // single-click selection. The earlier "highPriorityGesture hard-blocks
        // the drag" note applied to putting high priority on the tap that
        // competes with the drag; the double-tap does not compete with it.
        //   Double-click -> paste/activate (configurable primary action)
        //   Cmd-click     -> toggle this clip in the multi-selection
        //   Shift-click   -> extend the multi-selection range from the anchor
        //   Plain click   -> handleRowClick with no modifiers (select)
        .overlay { keyboardDecorations(index: index) }
        .onHover { inside in
            if inside { hoveredClipID = clip.id } else if hoveredClipID == clip.id { hoveredClipID = nil }
        }
        .highPriorityGesture(TapGesture(count: 2).onEnded { onPrimary(clip) })
        .simultaneousGesture(TapGesture(count: 1).onEnded { handleCardTap(clip, at: index) })
        .contextMenu { cardContextMenu(for: clip) }
        .popover(
            isPresented: Binding(
                get: { categoryCreationClip?.id == clip.id },
                set: { if !$0 { categoryCreationClip = nil } }
            )
        ) {
            categoryCreationPopover(for: clip)
        }
    }

    /// The card or row (per density) with every callback wired to the list actions.
    func cardBody(for clip: Clip, at index: Int, metadata: [Int64: CardMetadata]) -> some View {
        // Highlight reflects the explicit multi-selection when one exists;
        // otherwise it tracks the single keyboard-anchored row.
        let isSelected: Bool = {
            if selectedClipIDs.isEmpty { return index == selectedIndex }
            return clip.id.map { selectedClipIDs.contains($0) } ?? false
        }()
        let meta = clip.id.flatMap { metadata[$0] }
        let model = ClipCardModel.make(
            clip: clip,
            isSelected: isSelected,
            isPinned: meta?.isPinned ?? store.isPinned(clip),
            isSensitive: meta?.isSensitive ?? CardSensitivity.isSensitive(clip),
            isOCRRunning: store.ocrInFlightClipIDs.contains(clip.id ?? -1),
            query: store.query
        )
        let renaming = Binding(
            get: { renamingClipID == clip.id },
            set: { active in renamingClipID = active ? clip.id : nil }
        )
        let density = GridPreferences.shared.density
        let extract: (() -> Void)? = clip.isImageLike ? { runOCR(on: clip) } : nil
        let similar: (() -> Void)? = settings.suggestionsEnabled && clip.contentKind == .text
            ? { store.findSimilar(to: clip); selection = .suggestions }
            : nil
        return Group {
            if density == .cards {
                ClipCardView(
                    clip: clip,
                    model: model,
                    categoryColors: meta?.categoryColors ?? [],
                    pinnedCategory: meta?.pinnedCategory,
                    query: store.query,
                    isRenaming: renaming,
                    onActivate: { handleRowClick(clip, at: index, modifiers: []) },
                    onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
                    onPastePlain: { onPaste(clip, true) },
                    onSendKeystrokes: { requestSendKeystrokes(clip) },
                    onEdit: { onEdit(clip) },
                    onTogglePin: { store.togglePin(clip) },
                    onDelete: { requestDelete(clip) },
                    onRename: { store.renameClip(clip, userTitle: $0) },
                    onExtractText: extract,
                    onFindSimilar: similar,
                    onPasteFile: { onPasteFile(clip, false) },
                    onMoveFile: { onPasteFile(clip, true) },
                    aiMenuContent: settings.aiEnabled && clip.contentKind == .text && !model.isSensitive
                        ? { AnyView(aiMenuItems(for: clip)) }
                        : nil
                )
            } else {
                ClipRowView(
                    clip: clip,
                    model: model,
                    density: density,
                    query: store.query,
                    actions: ClipRowActions(
                        paste: { onPaste(clip, settings.pastePlainTextByDefault) },
                        pastePlain: { onPaste(clip, true) },
                        togglePin: { store.togglePin(clip) },
                        delete: { requestDelete(clip) },
                        beginRename: { renamingClipID = clip.id },
                        edit: clip.contentKind == .text && !model.isSensitive ? { onEdit(clip) } : nil,
                        extractText: extract,
                        findSimilar: similar
                    ),
                    pinnedCategory: meta?.pinnedCategory,
                    isRenaming: renaming,
                    onRename: { store.renameClip(clip, userTitle: $0) }
                )
            }
        }
        .id(clip.id)
    }

    /// Single-tap handler. NSEvent.modifierFlags reads the live keyboard state at
    /// click time; TapGesture carries no modifier info of its own.
    func handleCardTap(_ clip: Clip, at index: Int) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            handleRowClick(clip, at: index, modifiers: .command)
        } else if mods.contains(.shift) {
            handleRowClick(clip, at: index, modifiers: .shift)
        } else {
            handleRowClick(clip, at: index, modifiers: [])
        }
    }

    /// Body of the "new category" popover: creates the category and files the clip.
    @ViewBuilder
    func categoryCreationPopover(for clip: Clip) -> some View {
        CategoryEditorView(category: nil, knownBundleIDs: store.knownBundleIDs, existingNames: store.existingCategoryNames()) { name, colorHex, iconKind, iconValue in
            // Create the category and file the clip into it in one step.
            if let created = store.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue),
               let categoryID = created.id,
               let clipID = clip.id {
                store.addClip(id: clipID, toCategory: categoryID)
            }
        }
    }
}
