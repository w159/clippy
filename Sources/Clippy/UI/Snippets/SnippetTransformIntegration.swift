import SwiftUI

/// Entry points for the integrator: palette commands and context-menu items for transforms and snippets.
enum SnippetTransformIntegration {
    /// Palette commands. Closures are provided by the host (it owns sheet presentation and ClipStore).
    /// - Parameters:
    ///   - clip: selected clip, when any (enables "Transform clip…" / "New snippet from clip").
    ///   - transform: presents `TransformPickerView` for the clip.
    ///   - newSnippet: creates a snippet prefilled with the clip's text (skipped for sensitive clips).
    ///   - searchSnippets: opens the snippet search/insert list.
    static func paletteCommands(clip: Clip?, transform: @escaping (Clip) -> Void, newSnippet: @escaping (Clip) -> Void,
                                searchSnippets: @escaping () -> Void) -> [ClosurePaletteCommand] {
        let textClip = clip.flatMap { $0.contentKind == .text && !$0.contentText.isEmpty ? $0 : nil }
        let sensitive = textClip.map { SensitiveContent.isSensitive(clip: $0) } ?? false
        return [
            ClosurePaletteCommand(id: "transform-clip", title: "Transform clip…", subtitle: "Case, JSON, encode, hash, sort, regex",
                                  symbol: "wand.and.stars", keywords: ["convert", "base64", "json", "uppercase", "sort"],
                                  isEnabled: textClip != nil) { if let textClip { transform(textClip) } },
            ClosurePaletteCommand(id: "snippet-new-from-clip", title: "New snippet from clip", symbol: "text.badge.plus",
                                  keywords: ["save", "abbreviation"], isEnabled: textClip != nil && !sensitive) {
                if let textClip { newSnippet(textClip) }
            },
            ClosurePaletteCommand(id: "snippet-search", title: "Search snippets", subtitle: "Insert a saved snippet",
                                  symbol: "text.append", keywords: ["insert snippet", "expansion"], perform: searchSnippets)
        ]
    }

    /// Context-menu items: a "Transform" submenu of common transforms plus "Transform…" and "Save as snippet".
    @MainActor @ViewBuilder
    static func menuItems(for clip: Clip, openPicker: @escaping (Clip) -> Void, quick: @escaping (Clip, String) -> Void,
                          saveAsSnippet: @escaping (Clip) -> Void) -> some View {
        if clip.contentKind == .text, !clip.contentText.isEmpty {
            Menu("Transform") {
                ForEach(["case.upper", "case.lower", "case.title", "cleanup.trim", "json.pretty", "lines.sort.asc", "lines.dedupe"], id: \.self) { id in
                    if let item = TransformRegistry.transform(id: id) { Button(item.title) { quick(clip, id) } }
                }
                Divider()
                Button("More…") { openPicker(clip) }
            }
            if !SensitiveContent.isSensitive(clip: clip) { Button("Save as snippet") { saveAsSnippet(clip) } }
        }
    }
}
