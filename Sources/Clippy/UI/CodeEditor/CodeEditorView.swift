import AppKit
import SwiftUI

/// A reusable code editor: NSTextView with a line-number gutter, regex syntax
/// highlighting, auto-indent, Tab / Shift-Tab, bracket matching and a Cmd+S
/// callback, styled from the app theme.
///
///     CodeEditorView(text: $script.body, language: script.interpreter.codeLanguage,
///                    documentID: script.id, onSave: save)
///
/// Switching documents: pass a `documentID`. When it changes the whole editor
/// is rebuilt, so the undo stack of the previous document can never replay into
/// the next one. Outside changes to `text` (an AI rewrite, a reload) are applied
/// through `shouldChangeText`/`didChangeText`, so they are undoable and keep the
/// caret, and they never echo back into the binding.
struct CodeEditorView: View {
    @Binding var text: String
    var language: CodeLanguage
    /// Identity of the document being edited. Changing it resets the undo stack.
    var documentID: AnyHashable?
    var showsLineNumbers: Bool
    /// Wrap long lines instead of scrolling horizontally.
    var wrapsLines: Bool
    var isEditable: Bool
    var indentUnit: CodeIndentUnit
    var accessibilityLabel: String?
    /// Take keyboard focus as soon as the editor appears.
    var focusesOnAppear: Bool
    /// Called for Cmd+S while the editor has focus.
    var onSave: (() -> Void)?
    /// Point size override (font zoom); nil follows the app font size.
    var fontSize: CGFloat?
    /// Continuous spell and grammar checking. Off by default: code is not prose.
    var checksSpelling: Bool
    /// Smart quotes, dashes, text replacement, autocorrect and smart insert/delete.
    var usesSmartSubstitutions: Bool
    /// Reports the selection (UTF-16 range) after every caret move; nil to ignore.
    var onSelectionChange: ((NSRange) -> Void)?

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.clippyTokens) private var designTokens

    init(text: Binding<String>,
         language: CodeLanguage = .plain,
         documentID: AnyHashable? = nil,
         showsLineNumbers: Bool = true,
         wrapsLines: Bool = false,
         isEditable: Bool = true,
         indentUnit: CodeIndentUnit = .spaces(4),
         accessibilityLabel: String? = nil,
         focusesOnAppear: Bool = false,
         onSave: (() -> Void)? = nil,
         fontSize: CGFloat? = nil,
         checksSpelling: Bool = false,
         usesSmartSubstitutions: Bool = false,
         onSelectionChange: ((NSRange) -> Void)? = nil) {
        self._text = text
        self.language = language
        self.documentID = documentID
        self.showsLineNumbers = showsLineNumbers
        self.wrapsLines = wrapsLines
        self.isEditable = isEditable
        self.indentUnit = indentUnit
        self.accessibilityLabel = accessibilityLabel
        self.focusesOnAppear = focusesOnAppear
        self.onSave = onSave
        self.fontSize = fontSize
        self.checksSpelling = checksSpelling
        self.usesSmartSubstitutions = usesSmartSubstitutions
        self.onSelectionChange = onSelectionChange
    }

    var body: some View {
        CodeEditorRepresentable(
            text: $text, language: language, showsLineNumbers: showsLineNumbers, wrapsLines: wrapsLines,
            isEditable: isEditable, indentUnit: indentUnit, accessibilityLabel: accessibilityLabel,
            focusesOnAppear: focusesOnAppear, onSave: onSave,
            checksSpelling: checksSpelling, usesSmartSubstitutions: usesSmartSubstitutions,
            onSelectionChange: onSelectionChange,
            theme: CodeEditorTheme(design: designTokens, fontSize: fontSize ?? CGFloat(settings.fontSizeBase))
        )
        .id(documentID ?? AnyHashable(0))
    }
}

// MARK: - AppKit bridge

private struct CodeEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var showsLineNumbers: Bool
    var wrapsLines: Bool
    var isEditable: Bool
    var indentUnit: CodeIndentUnit
    var accessibilityLabel: String?
    var focusesOnAppear: Bool
    var onSave: (() -> Void)?
    var checksSpelling: Bool
    var usesSmartSubstitutions: Bool
    var onSelectionChange: ((NSRange) -> Void)?
    var theme: CodeEditorTheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wrapsLines
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // Explicit TextKit 1 stack: the gutter and bracket highlighting rely on
        // NSLayoutManager line fragments and temporary attributes.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let huge = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: wrapsLines ? 0 : huge, height: huge))
        container.widthTracksTextView = wrapsLines
        layout.addTextContainer(container)

        let view = CodeTextView(frame: .zero, textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: huge, height: huge)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = !wrapsLines
        view.autoresizingMask = wrapsLines ? [.width] : []
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        applyProofing(to: view)
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.delegate = context.coordinator
        scroll.documentView = view

        let ruler = LineNumberRulerView(scrollView: scroll, textView: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = showsLineNumbers

        if let accessibilityLabel { view.setAccessibilityLabel(accessibilityLabel) }

        let coordinator = context.coordinator
        coordinator.textView = view
        coordinator.ruler = ruler
        view.string = text
        coordinator.lastKnown = text
        apply(theme: theme, to: view, scroll: scroll, ruler: ruler)
        coordinator.appliedTheme = theme
        coordinator.appliedWrap = wrapsLines
        view.language = language
        view.indentUnit = indentUnit
        view.onSave = onSave
        view.isEditable = isEditable
        coordinator.rehighlight()
        ruler.reload()
        view.undoManager?.removeAllActions()

        if focusesOnAppear {
            // No window yet during make; defer one turn.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CodeTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        view.onSave = onSave
        view.indentUnit = indentUnit
        if view.isEditable != isEditable { view.isEditable = isEditable }
        scroll.rulersVisible = showsLineNumbers
        applyProofing(to: view)
        if coordinator.appliedWrap != wrapsLines {
            applyWrap(to: view, scroll: scroll)
            coordinator.appliedWrap = wrapsLines
        }

        var needsHighlight = false
        if coordinator.appliedTheme != theme {
            apply(theme: theme, to: view, scroll: scroll, ruler: coordinator.ruler)
            coordinator.appliedTheme = theme
            needsHighlight = true
        }
        if view.language != language {
            view.language = language
            needsHighlight = true
        }
        // Compare against the last value the view itself reported, not a
        // one-shot flag: a real outside change is applied every time, and an
        // echo of our own edit is never mistaken for one.
        if text != coordinator.lastKnown {
            coordinator.replaceContents(with: text)
            needsHighlight = false
        }
        if needsHighlight { coordinator.rehighlight() }
    }

    /// Spell checking and substitutions follow the caller; no other automatic
    /// text rewriting is ever enabled, so clip content is never silently altered.
    private func applyProofing(to view: CodeTextView) {
        if view.isContinuousSpellCheckingEnabled != checksSpelling {
            view.isContinuousSpellCheckingEnabled = checksSpelling
            view.isGrammarCheckingEnabled = checksSpelling
        }
        view.isAutomaticQuoteSubstitutionEnabled = usesSmartSubstitutions
        view.isAutomaticDashSubstitutionEnabled = usesSmartSubstitutions
        view.isAutomaticTextReplacementEnabled = usesSmartSubstitutions
        view.isAutomaticSpellingCorrectionEnabled = usesSmartSubstitutions
        view.smartInsertDeleteEnabled = usesSmartSubstitutions
    }

    /// Switches an existing editor between wrapping and horizontal scrolling
    /// without rebuilding it, so undo history and the caret survive.
    private func applyWrap(to view: CodeTextView, scroll: NSScrollView) {
        let huge = CGFloat.greatestFiniteMagnitude
        scroll.hasHorizontalScroller = !wrapsLines
        view.isHorizontallyResizable = !wrapsLines
        view.autoresizingMask = wrapsLines ? [.width] : []
        guard let container = view.textContainer else { return }
        container.widthTracksTextView = wrapsLines
        let width = wrapsLines ? max(0, scroll.contentSize.width) : huge
        container.containerSize = NSSize(width: width, height: huge)
        if wrapsLines { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
        view.layoutManager?.ensureLayout(for: container)
        view.needsDisplay = true
    }

    private func apply(theme: CodeEditorTheme, to view: CodeTextView, scroll: NSScrollView, ruler: LineNumberRulerView?) {
        view.font = theme.font
        view.textColor = theme.text
        view.backgroundColor = theme.background
        view.insertionPointColor = theme.caret
        view.selectedTextAttributes = [.backgroundColor: theme.selection]
        view.bracketColor = theme.bracketHighlight
        view.typingAttributes = [.font: theme.font, .foregroundColor: theme.text]
        scroll.backgroundColor = theme.background
        ruler?.gutterFont = .monospacedDigitSystemFont(ofSize: max(9, theme.font.pointSize - 2), weight: .regular)
        ruler?.textColor = theme.gutterText
        ruler?.backgroundColor = theme.gutterBackground
        ruler?.needsDisplay = true
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorRepresentable
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRulerView?
        var appliedTheme: CodeEditorTheme?
        var appliedWrap = false
        /// The text the view last reported (or was last given). Distinguishes an
        /// outside change from the echo of the user's own typing.
        var lastKnown = ""
        private var applyingExternalChange = false

        init(parent: CodeEditorRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CodeTextView else { return }
            let current = view.string
            lastKnown = current
            rehighlight()
            if applyingExternalChange { return }
            parent.text = current
        }

        /// Publishes the caret/selection asynchronously: it can change while SwiftUI
        /// is updating the view, where a synchronous state write is not allowed.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? CodeTextView, let report = parent.onSelectionChange else { return }
            let range = view.selectedRange()
            DispatchQueue.main.async { report(range) }
        }

        /// Replaces the whole document through the text system's change
        /// protocol so undo, the ruler and the delegate all see it, keeping the
        /// caret where it was (clamped).
        func replaceContents(with newText: String) {
            guard let view = textView, let storage = view.textStorage else { return }
            let selected = view.selectedRange()
            let full = NSRange(location: 0, length: storage.length)
            applyingExternalChange = true
            defer { applyingExternalChange = false }
            if view.shouldChangeText(in: full, replacementString: newText) {
                storage.replaceCharacters(in: full, with: newText)
                view.didChangeText()
            }
            let length = (newText as NSString).length
            view.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
            view.resetBracketHighlight()
        }

        /// Re-applies base attributes and token colors over the whole text.
        func rehighlight() {
            guard let view = textView, let storage = view.textStorage, let theme = appliedTheme else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: theme.font, .foregroundColor: theme.text], range: full)
            for token in SyntaxHighlighter.tokens(in: storage.string, language: view.language)
            where NSMaxRange(token.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
            }
            storage.endEditing()
            view.updateBracketHighlight()
        }
    }
}
