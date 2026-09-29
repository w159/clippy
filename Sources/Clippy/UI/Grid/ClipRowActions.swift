import SwiftUI

/// Closure bundle shared by cards and rows for accessibility actions and menus.
struct ClipRowActions {
    var paste: () -> Void
    var pastePlain: () -> Void
    var togglePin: () -> Void
    var delete: () -> Void
    var beginRename: () -> Void
    /// Nil for clips that cannot be edited (images, files).
    var edit: (() -> Void)?
    /// Nil unless the clip is image-like.
    var extractText: (() -> Void)?
    /// Nil unless similarity search is available.
    var findSimilar: (() -> Void)?
}

/// A11Y-01: one combined element per card or row, named actions instead of
/// separate buttons, and a label that never contains masked content.
struct ClipAccessibilityModifier: ViewModifier {
    let model: ClipCardModel
    let actions: ClipRowActions

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityValue(model.accessibilityValue)
            .accessibilityAddTraits(model.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Activate to paste. Use actions for more.")
            .accessibilityActions {
                Button("Paste", action: actions.paste)
                Button("Paste as plain text", action: actions.pastePlain)
                Button(model.isPinned ? "Unpin" : "Pin", action: actions.togglePin)
                Button("Rename", action: actions.beginRename)
                if let edit = actions.edit { Button("Edit", action: edit) }
                if let extract = actions.extractText { Button("Extract text", action: extract) }
                if let similar = actions.findSimilar { Button("Find similar", action: similar) }
                Button("Delete", action: actions.delete)
            }
    }
}

extension View {
    /// Applies the shared clip accessibility contract.
    func clipAccessibility(model: ClipCardModel, actions: ClipRowActions) -> some View {
        modifier(ClipAccessibilityModifier(model: model, actions: actions))
    }
}
