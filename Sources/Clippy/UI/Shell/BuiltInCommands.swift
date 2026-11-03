import Foundation

/// Everything the built-in palette commands need from the panel. The panel
/// fills the closures; a nil `selectedClip` disables the clip actions (only
/// valid actions are listed).
struct PanelCommandContext {
    var hasSelectedClip: Bool
    var hasQuery: Bool
    var canExtractText: Bool
    var canFindSimilar: Bool
    var isPinned: Bool
    var paste: () -> Void
    var pastePlain: () -> Void
    var togglePin: () -> Void
    var deleteSelection: () -> Void
    var findSimilar: () -> Void
    var openSettings: () -> Void
    var toggleSidebar: () -> Void
    var currentDensity: ClipDensity
    var setDensity: (ClipDensity) -> Void
    var suggestionsEnabled: Bool
    var toggleSuggestions: () -> Void
    var clearSearch: () -> Void
    var extractText: () -> Void
    var newCategory: () -> Void
    /// Commands contributed by feature modules (preview, paste stack, snippets/transforms, semantic); already gated for sensitive clips.
    var featureCommands: [any PaletteCommand] = []
    /// Clips the delete command acts on; 2+ means the whole multi-selection, as Cmd+Delete does.
    var selectionCount: Int = 1
    /// Rename, plain-text copy and reveal: the context-menu actions that had no command.
    var rename: () -> Void = {}
    var copyPlain: () -> Void = {}
    var toggleReveal: () -> Void = {}
    /// True when the selection is a single sensitive clip.
    var canReveal = false
    /// Categories offered as "Move to ..." commands, and the action that files the selection.
    var moveTargets: [(id: Int64, name: String)] = []
    var moveToCategory: (Int64) -> Void = { _ in }
}

/// The palette's built-in command set.
enum BuiltInCommands {
    /// Stable identifiers, also used by tests.
    static let identifiers = [
        "paste", "paste-plain", "pin", "delete", "similar", "settings",
        "sidebar", "density-compact", "density-comfortable", "density-cards", "clear-search",
        "extract-text", "new-category", "suggestions", "rename", "copy-plain", "reveal"
    ]

    /// Built-ins followed by the feature commands, as the palette host shows them.
    static func all(_ context: PanelCommandContext) -> [any PaletteCommand] {
        make(context) + context.featureCommands
    }

    /// Builds the built-in commands for `context`.
    static func make(_ context: PanelCommandContext) -> [ClosurePaletteCommand] {
        clipCommands(context) + navigationCommands(context)
    }

    /// Clip actions, including the ones the context menu alone used to offer.
    private static func clipCommands(_ context: PanelCommandContext) -> [ClosurePaletteCommand] {
        let clip = context.hasSelectedClip
        let moves = context.moveTargets.map { target in
            ClosurePaletteCommand(id: "move-\(target.id)", title: "Move to \(target.name)", symbol: "folder",
                                  keywords: ["category", "file", "board"], isEnabled: clip,
                                  perform: { context.moveToCategory(target.id) })
        }
        return [
            ClosurePaletteCommand(id: "paste", title: "Paste", symbol: "doc.on.clipboard", keywords: ["insert"],
                                  shortcut: "\u{21A9}", isEnabled: clip, perform: context.paste),
            ClosurePaletteCommand(id: "paste-plain", title: "Paste as Plain Text", symbol: "text.alignleft",
                                  keywords: ["unformatted", "strip"], shortcut: "\u{21E7}\u{21A9}", isEnabled: clip,
                                  perform: context.pastePlain),
            ClosurePaletteCommand(id: "copy-plain", title: "Copy as Plain Text", symbol: "doc.on.doc",
                                  keywords: ["unformatted", "strip", "copy"], shortcut: "\u{21E7}\u{2318}C",
                                  isEnabled: clip, perform: context.copyPlain),
            ClosurePaletteCommand(id: "rename", title: "Rename", symbol: "character.cursor.ibeam",
                                  keywords: ["title", "label"], shortcut: "\u{2318}R",
                                  isEnabled: clip && context.selectionCount < 2, perform: context.rename),
            ClosurePaletteCommand(id: "reveal", title: "Reveal or Hide Sensitive Content", symbol: "eye",
                                  keywords: ["show", "mask", "secret"], shortcut: "\u{21E7}\u{2318}R",
                                  isEnabled: context.canReveal, perform: context.toggleReveal),
            ClosurePaletteCommand(id: "pin", title: context.isPinned ? "Unpin" : "Pin", symbol: "pin",
                                  keywords: ["favorite", "keep"], shortcut: "\u{2318}P", isEnabled: clip,
                                  perform: context.togglePin),
            ClosurePaletteCommand(id: "delete", title: context.selectionCount >= 2 ? "Delete \(context.selectionCount) Clips" : "Delete", symbol: "trash", keywords: ["remove"],
                                  shortcut: "\u{2318}\u{232B}", isEnabled: clip, perform: context.deleteSelection),
            ClosurePaletteCommand(id: "similar", title: "Find Similar", symbol: "sparkle.magnifyingglass",
                                  keywords: ["related", "suggest"], isEnabled: clip && context.canFindSimilar, perform: context.findSimilar),
            ClosurePaletteCommand(id: "extract-text", title: "Extract Text", subtitle: "Recognize text in the image",
                                  symbol: "text.viewfinder", keywords: ["ocr", "recognize"],
                                  isEnabled: context.canExtractText, perform: context.extractText)
        ] + moves
    }

    /// Search, layout and settings commands.
    private static func navigationCommands(_ context: PanelCommandContext) -> [ClosurePaletteCommand] {
        let clip = context.hasSelectedClip
        return [
            ClosurePaletteCommand(id: "clear-search", title: "Clear Search", symbol: "xmark.circle",
                                  keywords: ["reset", "filter"], section: .navigate, isEnabled: context.hasQuery,
                                  perform: context.clearSearch),
            ClosurePaletteCommand(id: "sidebar", title: "Toggle Sidebar", symbol: "sidebar.left",
                                  keywords: ["collapse", "rail", "categories"], section: .navigate,
                                  perform: context.toggleSidebar),
            densityCommand(.compact, id: "density-compact", context: context),
            densityCommand(.comfortable, id: "density-comfortable", context: context),
            densityCommand(.cards, id: "density-cards", context: context),
            ClosurePaletteCommand(id: "suggestions",
                                  title: context.suggestionsEnabled ? "Turn Off Suggestions" : "Turn On Suggestions",
                                  subtitle: "Toggle Suggestions", symbol: "sparkles",
                                  keywords: ["smart", "toggle", "suggestions"], section: .settings,
                                  perform: context.toggleSuggestions),
            ClosurePaletteCommand(id: "new-category", title: "New Category", symbol: "folder.badge.plus",
                                  keywords: ["create", "folder", "board"], section: .navigate,
                                  isEnabled: clip, perform: context.newCategory),
            ClosurePaletteCommand(id: "settings", title: "Open Settings", symbol: "gearshape",
                                  keywords: ["preferences", "options"], shortcut: "\u{2318},", section: .settings,
                                  perform: context.openSettings)
        ]
    }

    private static func densityCommand(_ density: ClipDensity, id: String,
                                       context: PanelCommandContext) -> ClosurePaletteCommand {
        ClosurePaletteCommand(id: id, title: "Change Density: \(density.title)", symbol: density.symbolName,
                              keywords: ["view", "layout", "grid", "density", density.rawValue],
                              section: .navigate, isEnabled: context.currentDensity != density,
                              perform: { context.setDensity(density) })
    }
}
