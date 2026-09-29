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
}

/// The palette's built-in command set.
enum BuiltInCommands {
    /// Stable identifiers, also used by tests.
    static let identifiers = [
        "paste", "paste-plain", "pin", "delete", "similar", "settings",
        "sidebar", "density-compact", "density-comfortable", "density-cards", "clear-search",
        "extract-text", "new-category", "suggestions"
    ]

    /// Built-ins followed by the feature commands, as the palette host shows them.
    static func all(_ context: PanelCommandContext) -> [any PaletteCommand] {
        make(context) + context.featureCommands
    }

    /// Builds the built-in commands for `context`.
    static func make(_ context: PanelCommandContext) -> [ClosurePaletteCommand] {
        let clip = context.hasSelectedClip
        return [
            ClosurePaletteCommand(id: "paste", title: "Paste", symbol: "doc.on.clipboard", keywords: ["insert"],
                                  shortcut: "\u{21A9}", isEnabled: clip, perform: context.paste),
            ClosurePaletteCommand(id: "paste-plain", title: "Paste as plain text", symbol: "text.alignleft",
                                  keywords: ["unformatted", "strip"], shortcut: "\u{21E7}\u{21A9}", isEnabled: clip,
                                  perform: context.pastePlain),
            ClosurePaletteCommand(id: "pin", title: context.isPinned ? "Unpin" : "Pin", symbol: "pin",
                                  keywords: ["favorite", "keep"], shortcut: "\u{2318}P", isEnabled: clip,
                                  perform: context.togglePin),
            ClosurePaletteCommand(id: "delete", title: "Delete", symbol: "trash", keywords: ["remove"],
                                  shortcut: "\u{2318}\u{232B}", isEnabled: clip, perform: context.deleteSelection),
            ClosurePaletteCommand(id: "similar", title: "Find similar", symbol: "sparkle.magnifyingglass",
                                  keywords: ["related", "suggest"], isEnabled: clip && context.canFindSimilar, perform: context.findSimilar),
            ClosurePaletteCommand(id: "extract-text", title: "Extract text", subtitle: "Recognise text in the image",
                                  symbol: "text.viewfinder", keywords: ["ocr", "recognize"],
                                  isEnabled: context.canExtractText, perform: context.extractText),
            ClosurePaletteCommand(id: "clear-search", title: "Clear search", symbol: "xmark.circle",
                                  keywords: ["reset", "filter"], section: .navigate, isEnabled: context.hasQuery,
                                  perform: context.clearSearch),
            ClosurePaletteCommand(id: "sidebar", title: "Toggle sidebar", symbol: "sidebar.left",
                                  keywords: ["collapse", "rail", "categories"], section: .navigate,
                                  perform: context.toggleSidebar),
            densityCommand(.compact, id: "density-compact", context: context),
            densityCommand(.comfortable, id: "density-comfortable", context: context),
            densityCommand(.cards, id: "density-cards", context: context),
            ClosurePaletteCommand(id: "suggestions",
                                  title: context.suggestionsEnabled ? "Turn off Suggestions" : "Turn on Suggestions",
                                  subtitle: "Toggle Suggestions", symbol: "sparkles",
                                  keywords: ["smart", "toggle", "suggestions"], section: .settings,
                                  perform: context.toggleSuggestions),
            ClosurePaletteCommand(id: "new-category", title: "New category", symbol: "folder.badge.plus",
                                  keywords: ["create", "folder", "board"], section: .navigate,
                                  isEnabled: clip, perform: context.newCategory),
            ClosurePaletteCommand(id: "settings", title: "Open Settings", symbol: "gearshape",
                                  keywords: ["preferences", "options"], shortcut: "\u{2318},", section: .settings,
                                  perform: context.openSettings)
        ]
    }

    private static func densityCommand(_ density: ClipDensity, id: String,
                                       context: PanelCommandContext) -> ClosurePaletteCommand {
        ClosurePaletteCommand(id: id, title: "Change density: \(density.title)", symbol: density.symbolName,
                              keywords: ["view", "layout", "grid", "density", density.rawValue],
                              section: .navigate, isEnabled: context.currentDensity != density,
                              perform: { context.setDensity(density) })
    }
}
