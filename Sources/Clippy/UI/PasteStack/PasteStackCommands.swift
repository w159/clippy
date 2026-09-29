import AppKit
import SwiftUI

/// Merge / append actions over selected clips (FEAT-13). Sensitive clips are
/// always excluded.
enum ClipMergeActions {
    /// Text clips from `clips` that are not sensitive.
    static func eligible(_ clips: [Clip], isSensitive: (Clip) -> Bool = { SensitiveContent.isSensitive(clip: $0) }) -> [Clip] {
        clips.filter { !isSensitive($0) }
    }

    /// Saves the merge of the eligible clips as a new clip; returns its id (nil when nothing qualified).
    @discardableResult
    static func mergeSelected(_ clips: [Clip], separator: MergeSeparator = AppendPreferences.mergeSeparator,
                              database: ClipDatabase) -> Int64? {
        try? ClipMerge.saveMerged(eligible(clips), separator: separator.text, into: database)
    }

    /// Appends the clipboard's current text to `clip`; false when refused (sensitive, non-text, blank).
    @discardableResult
    static func appendClipboard(to clip: Clip, database: ClipDatabase, pasteboard: NSPasteboard = .general,
                                separator: MergeSeparator = AppendPreferences.separator) -> Bool {
        guard !SensitiveContent.isSensitive(clip: clip),
              let text = pasteboard.string(forType: .string), !SensitiveContent.isSensitive(text: text)
        else { return false }
        return (try? ClipMerge.append(text, to: clip, separator: separator.text, in: database)) ?? false
    }
}

/// Palette commands and context-menu items for the paste stack and merge.
enum PasteStackCommands {
    /// Palette commands. `selectedClips` supplies the panel's current selection.
    @MainActor
    static func make(controller: PasteStackController = .shared, selectedClips: @escaping () -> [Clip],
                     database: @escaping () -> ClipDatabase) -> [ClosurePaletteCommand] {
        let stack = controller.stack
        let selection = selectedClips()
        return [
            ClosurePaletteCommand(id: "paste-stack-toggle", title: stack.isCollecting ? "Stop collecting paste stack" : "Start collecting paste stack",
                                  symbol: "square.stack.3d.down.right", keywords: ["queue", "sequential", "collect"]) {
                NotificationCenter.default.post(name: .clippyPasteStackToggle, object: nil)
            },
            ClosurePaletteCommand(id: "paste-stack-next", title: "Paste next from stack", subtitle: "\(stack.count) queued",
                                  symbol: "arrow.down.doc", keywords: ["queue", "sequential"], isEnabled: stack.count > 0) {
                controller.pasteNext()
            },
            ClosurePaletteCommand(id: "paste-stack-clear", title: "Clear paste stack", symbol: "trash",
                                  isEnabled: stack.count > 0) { stack.clear() },
            ClosurePaletteCommand(id: "merge-selected", title: "Merge selected clips", symbol: "arrow.triangle.merge",
                                  keywords: ["combine", "join"], isEnabled: selection.count > 1) {
                ClipMergeActions.mergeSelected(selection, database: database())
            },
            ClosurePaletteCommand(id: "append-clipboard", title: "Append clipboard to selected clip", symbol: "text.append",
                                  keywords: ["add"], isEnabled: selection.count == 1) {
                if let clip = selection.first { ClipMergeActions.appendClipboard(to: clip, database: database()) }
            }
        ]
    }
}

/// Context-menu items: "Add to Paste Stack" and "Merge with Selection".
@MainActor @ViewBuilder
func pasteStackMenuItems(for clip: Clip, selection: [Clip], database: ClipDatabase,
                         controller: PasteStackController = .shared) -> some View {
    Button("Add to Paste Stack") { controller.add(clip) }
    let others = selection.filter { $0.id != clip.id }
    Button("Merge with Selection") { ClipMergeActions.mergeSelected([clip] + others, database: database) }
        .disabled(others.isEmpty)
}
