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

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.allowsUndo = true
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

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        // Keep the label in sync if a caller re-renders with a different one.
        if let label = accessibilityLabel, textView.accessibilityLabel() != Optional(label) {
            textView.setAccessibilityLabel(label)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
