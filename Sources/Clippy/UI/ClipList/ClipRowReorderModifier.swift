import SwiftUI
import AppKit

// Within-category reorder drag/drop modifier applied to every clip card.

/// Applied to every clip card in the list. Owns the single .draggable for
/// each row so there is never more than one drag payload per view (SwiftUI
/// only honours the innermost payload when multiple .draggable modifiers are
/// stacked, silently discarding the rest).
///
/// - History pane (categoryID == nil): emits "clip:<id>" so CategorySidePane's
///   drop can file the clip by matching the TYPE TAG, never by comparing the
///   integer to known category IDs.
/// - Category pane (categoryID set): emits "reorder:clip:<id>" (kind "clip") so
///   CategorySidePane's drop can distinguish this from category-reorder tokens
///   ("reorder:cat:<id>") purely by tag, with no value-based id check.
///   Within-list reorder also uses kind "clip" and only accepts "reorder:clip:<id>".
struct CategoryReorderModifier: ViewModifier {
    let clipID: Int64
    let categoryID: Int64?
    /// Drag-hover lives here, not in the list, so hovering a drag over one row
    /// never invalidates the whole list (LAY-12).
    @State private var draggingOverClipID: Int64?
    let store: ClipStore
    /// Builds the single drag payload (in-app token plus external content, see
    /// `ClipDragItem`). Evaluated lazily at drag start.
    let item: () -> ClipDragItem

    func body(content: Content) -> some View {
        guard let categoryID else {
            // History pane: "clip:<id>" payload so CategorySidePane's drop handler
            // can branch on the TYPE TAG rather than checking whether the integer
            // matches a known category. A clip whose Int64 id happens to equal an
            // existing category id would otherwise be silently rejected.
            return AnyView(content.draggable(item()))
        }
        return AnyView(
            content
                // "clip" kind tag so CategorySidePane's drop can distinguish
                // "reorder:clip:<id>" from "reorder:cat:<id>" by TAG alone.
                // Previously both used plain "reorder:<id>", requiring a
                // store.categories.contains() value check that silently misfired
                // when clip.id happened to equal a category id.
                .draggable(item())
                .reorderDropDestination(
                    id: clipID,
                    kind: "clip",
                    draggingOver: $draggingOverClipID
                ) { draggedID, targetID in
                    store.moveClip(draggedID, inCategory: categoryID, before: targetID)
                }
        )
    }
}
