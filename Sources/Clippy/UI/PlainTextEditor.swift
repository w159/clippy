import AppKit
import SwiftUI

/// NSTextView wrapper with every automatic substitution disabled. This is
/// the fix for clipboard managers mangling straight quotes into curly ones
/// and hyphens into dashes: no rich-text round-trip, no smart substitutions.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    // Optional accessibility label so VoiceOver announces the field's purpose
    // instead of only the raw text. Defaults to nil so existing callers that
    // do not pass a label compile unchanged.
    var accessibilityLabel: String? = nil
    // Optional typography/theme overrides. SwiftUI .font/.foregroundStyle
    // modifiers never reach the wrapped NSTextView, so callers that want the
    // editor to honor the user's panel typography pass AppKit values here.
    // Defaults keep existing callers (ScriptsView) compiling and looking the
    // same as before.
    var font: NSFont? = nil
    var textColor: NSColor? = nil
    var backgroundColor: NSColor? = nil
    // When true, the text view becomes first responder as soon as it lands in
    // a window, so the user can type immediately after the editor opens.
    var focusesOnAppear: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        textView.font = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        if let textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
        if let backgroundColor {
            textView.backgroundColor = backgroundColor
            scrollView.backgroundColor = backgroundColor
        }
        textView.allowsUndo = true
        // Built-in find bar: Cmd+F (via the Edit > Find menu items) opens
        // incremental find/replace over the text without any custom search UI.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.string = text
        // Apply the accessibility label if one was supplied so screen readers
        // announce the field's purpose (e.g. "Script body") rather than only
        // reading the raw text content.
        if let label = accessibilityLabel {
            textView.setAccessibilityLabel(label)
        }
        if focusesOnAppear {
            // The view has no window yet during makeNSView; defer one turn so
            // makeFirstResponder has a window to talk to.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        if coordinator.isEditingFromTextView {
            // Self-originated change: the text view is already the source of
            // truth, so skip the O(n) string compare and re-assignment that
            // used to run on every keystroke. The flag is consumed here so the
            // next genuinely external update takes the branch below.
            coordinator.isEditingFromTextView = false
        } else if textView.string != text {
            // External update (e.g. an AI action rewrote the text). Replace via
            // textStorage instead of textView.string so the insertion point
            // survives instead of jumping to the end of the document.
            replaceTextPreservingSelection(in: textView, with: text)
        }
        // Keep typography in sync when the user changes font/theme settings
        // while the editor is open. NSFont/NSColor equality is cheap.
        if let font, textView.font != font {
            textView.font = font
        }
        if let textColor, textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
        if let backgroundColor, textView.backgroundColor != backgroundColor {
            textView.backgroundColor = backgroundColor
            scrollView.backgroundColor = backgroundColor
        }
        // Keep the label in sync if a caller re-renders with a different one.
        if let label = accessibilityLabel, textView.accessibilityLabel() != Optional(label) {
            textView.setAccessibilityLabel(label)
        }
    }

    /// Swap the full document contents while keeping the caret where it was
    /// (clamped to the new length). Programmatic textStorage edits do not fire
    /// textDidChange, so this cannot echo back into the binding.
    private func replaceTextPreservingSelection(in textView: NSTextView, with newText: String) {
        let selected = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.replaceCharacters(in: fullRange, with: newText)
        let newLength = (newText as NSString).length
        textView.setSelectedRange(NSRange(location: min(selected.location, newLength), length: 0))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        /// Set when the user types, consumed by the next updateNSView so the
        /// round-trip render for a self-originated edit skips the full-string
        /// compare (which is O(n) per keystroke on large clips).
        var isEditingFromTextView = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditingFromTextView = true
            text.wrappedValue = textView.string
        }
    }
}
