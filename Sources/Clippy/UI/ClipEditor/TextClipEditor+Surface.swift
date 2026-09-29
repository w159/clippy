import AppKit
import SwiftUI

// The editing surface: code editor or rich editor, with an optional preview pane.
extension TextClipEditor {
    /// Grammar in effect: the user's choice, else the sniffed one.
    var language: CodeLanguage { languageOverride ?? detectedLanguage }

    var category: EditorContentCategory { richMode ? .prose : EditorContentCategory(language: language) }

    /// Size in effect: the persisted zoom, else the app font size.
    var effectiveFontSize: Double { prefs.fontSize ?? Double(settings.fontSizeBase) }

    /// Which preview applies to the current mode, if any.
    enum PreviewKind { case markdown, csv, rich }

    var previewKind: PreviewKind? {
        if richMode { return nil }
        switch language {
        case .markdown: return .markdown
        case .csv: return csvTable == nil ? nil : .csv
        default: return richSource == nil ? nil : .rich
        }
    }

    @ViewBuilder
    var editingSurface: some View {
        if richMode {
            richEditor
        } else if prefs.previewVisible, let kind = previewKind {
            HSplitView {
                codeEditor.frame(minWidth: 220)
                previewPane(kind).frame(minWidth: 200)
            }
        } else {
            codeEditor
        }
    }

    var codeEditor: some View {
        CodeEditorView(
            text: $text,
            language: language,
            documentID: clip.id.map { AnyHashable($0) },
            showsLineNumbers: prefs.showsLineNumbers,
            wrapsLines: prefs.wraps(category),
            accessibilityLabel: "Clip text",
            focusesOnAppear: true,
            onSave: { if isDirty, !clipDeleted, save() { onClose() } },
            fontSize: CGFloat(effectiveFontSize),
            checksSpelling: prefs.checksSpelling(category),
            usesSmartSubstitutions: prefs.usesSmartSubstitutions(category),
            onSelectionChange: { selectionRange = $0 }
        )
    }

    /// The macOS 26 SwiftUI rich `TextEditor` over an `AttributedString`. The
    /// package's deployment target is macOS 26, so no availability guard is needed.
    var richEditor: some View {
        TextEditor(text: $richText)
            .scrollContentBackground(.hidden)
            .foregroundStyle(tokens.textPrimary)
            .background(tokens.cardSurface)
            .accessibilityLabel("Rich clip text")
            .focused($richFocused)
    }

    @ViewBuilder
    func previewPane(_ kind: PreviewKind) -> some View {
        switch kind {
        case .markdown: MarkdownPreviewPane(markdown: previewText)
        case .csv:
            if let table = csvTable { CSVTablePreview(table: table) }
        case .rich:
            if let richSource { RichPreviewView(content: richSource) }
        }
    }

    // MARK: Rich / plain switching

    /// Toggles between the rich editor and the plain-text editor.
    func setRichMode(_ enabled: Bool) {
        guard enabled != richMode, richSource != nil else { return }
        if enabled {
            if String(richText.characters) != text {
                richText = AttributedString(text)
                richEdited = text != baseText
            }
            richMode = true
        } else {
            richMode = false
            showStatus("Plain text mode: saving removes the formatting")
        }
    }
}
