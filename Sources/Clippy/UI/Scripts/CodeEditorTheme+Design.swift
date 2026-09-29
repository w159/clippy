import AppKit
import SwiftUI

extension CodeEditorTheme {
    /// Builds the editor theme from the design-system tokens so text, gutter and
    /// syntax colours keep the contrast the token resolver guarantees (AA, or the
    /// enhanced ratio under Increase Contrast). Surfaces stay on the legacy
    /// palette so the editor matches the rest of the window.
    init(design: ClippyTokens, fontSize: CGFloat) {
        self.init(tokens: design.legacy, fontSize: fontSize)
        text = NSColor(design.textPrimary)
        caret = NSColor(design.accentText)
        selection = NSColor(design.accentText).withAlphaComponent(0.28)
        gutterText = NSColor(design.textSecondary)
        gutterBackground = NSColor(design.surfaceInset)
        background = NSColor(design.surface)
        tokenColors[.keyword] = NSColor(design.accentText)
        tokenColors[.string] = NSColor(design.success)
        tokenColors[.comment] = NSColor(design.textSecondary)
        tokenColors[.number] = NSColor(design.danger)
        tokenColors[.op] = NSColor(design.textSecondary)
    }
}
