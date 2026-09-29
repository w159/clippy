import SwiftUI

/// Entry points the integrator wires into the palette and clip context menu.
/// Handlers are closures so this file stays independent of ClipStore.
enum SemanticIntegration {
    /// Palette commands for the currently selected clip (nil = no selection, commands disabled).
    static func paletteCommands(
        hasSelection: Bool, hasImageSelection: Bool, translate: @escaping () -> Void,
        describe: @escaping () -> Void, suggestCategory: @escaping () -> Void
    ) -> [PaletteCommand] {
        [
            ClosurePaletteCommand(
                id: "semantic.translate", title: "Translate clip", subtitle: "On-device", symbol: "character.bubble",
                keywords: ["translation", "language"], isEnabled: hasSelection && !hasImageSelection, perform: translate),
            ClosurePaletteCommand(
                id: "semantic.describe", title: "Describe image", subtitle: "On-device", symbol: "text.viewfinder",
                keywords: ["vision", "ocr", "caption"], isEnabled: hasImageSelection, perform: describe),
            ClosurePaletteCommand(
                id: "semantic.suggestCategory", title: "Suggest category", subtitle: "On-device", symbol: "tray.and.arrow.down",
                keywords: ["file", "autofile", "organize"], isEnabled: hasSelection, perform: suggestCategory),
        ]
    }

    /// Context-menu items for `clip`. Translate is text-only; Describe is image-only.
    @ViewBuilder
    static func menuItems(
        for clip: Clip, translate: @escaping () -> Void, describe: @escaping () -> Void,
        suggestCategory: @escaping () -> Void
    ) -> some View {
        if clip.contentKind == .text { Button("Translate\u{2026}", action: translate) }
        if clip.contentKind == .image { Button("Describe Image\u{2026}", action: describe) }
        Button("Suggest Category", action: suggestCategory)
    }
}
