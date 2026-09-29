import AppKit
import SwiftUI

/// Colors and font for the code editor and its gutter, derived from the app's
/// `ThemeTokens` so a theme switch repaints the editor with everything else.
struct CodeEditorTheme {
    var font: NSFont
    var background: NSColor
    var text: NSColor
    var caret: NSColor
    var selection: NSColor
    var gutterBackground: NSColor
    var gutterText: NSColor
    var bracketHighlight: NSColor
    var tokenColors: [CodeTokenKind: NSColor]

    func color(for kind: CodeTokenKind) -> NSColor { tokenColors[kind] ?? text }

    /// Builds a theme from the app tokens. The accent, success and danger
    /// tokens color keywords, strings and numbers; the remaining classes use a
    /// fixed palette tuned for the token table's light or dark base.
    init(tokens: ThemeTokens, fontSize: CGFloat) {
        let dark = tokens.isDark
        func hex(_ light: UInt32, _ darkValue: UInt32) -> NSColor {
            let value = dark ? darkValue : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        background = NSColor(tokens.scrollBackground)
        text = NSColor(tokens.textPrimary)
        caret = NSColor(tokens.accent)
        selection = NSColor(tokens.accent).withAlphaComponent(0.28)
        gutterBackground = NSColor(tokens.headerBar)
        gutterText = NSColor(tokens.textSecondary)
        bracketHighlight = NSColor(tokens.accent).withAlphaComponent(0.35)
        tokenColors = [
            .keyword: NSColor(tokens.accent),
            .string: NSColor(tokens.success),
            .comment: NSColor(tokens.textSecondary),
            .number: NSColor(tokens.danger),
            .type: hex(0x1A7F8E, 0x56B6C2),
            .function: hex(0x0969DA, 0x61AFEF),
            .variable: hex(0x9A5B13, 0xD19A66),
            .attribute: hex(0x8250DF, 0xC678DD),
            .op: NSColor(tokens.textSecondary),
        ]
    }

    /// The theme for the current app settings.
    @MainActor
    static func current(settings: AppSettings = .shared) -> CodeEditorTheme {
        CodeEditorTheme(tokens: settings.theme, fontSize: CGFloat(settings.fontSizeBase))
    }
}

extension ScriptInterpreter {
    /// Highlighting grammar for this interpreter.
    var codeLanguage: CodeLanguage {
        switch self {
        case .zsh, .bash, .sh: return .shell
        case .python3: return .python
        case .node: return .javascript
        case .ruby: return .ruby
        case .applescript: return .applescript
        case .swift: return .swift
        }
    }
}

extension CodeEditorTheme: Equatable {}
