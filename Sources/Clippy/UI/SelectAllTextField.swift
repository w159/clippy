import AppKit
import SwiftUI

// SwiftUI's TextField cannot focus-and-select-all on appear, and styling its
// background for contrast is awkward. This AppKit-backed field does both: it
// becomes first responder and selects its whole contents the moment it appears,
// so choosing "Rename" drops the cursor in with the current title highlighted,
// ready to overtype. It is self-contained: commit/cancel report the field's own
// value, so there is no binding-timing race with the initial selection.
struct SelectAllTextField: NSViewRepresentable {
    let initialText: String
    var font: NSFont
    var textColor: NSColor
    // Optional accessibility label so VoiceOver announces the field's purpose
    // (e.g. "Rename clip") instead of only the selected text. Defaults to nil
    // so existing callers that do not pass a label compile unchanged.
    var accessibilityLabel: String? = nil
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

    func makeNSView(context: Context) -> FocusSelectTextField {
        let field = FocusSelectTextField(string: initialText)
        field.font = font
        field.textColor = textColor
        field.delegate = context.coordinator
        field.isBordered = false
        // Keep the system focus ring so focus is always visible (WCAG 2.4.7)
        // even when a caller forgets to add an accent overlay. Callers that
        // draw their own accent ring can still do so on top; the native ring
        // guarantees a baseline visible-focus affordance.
        field.focusRingType = .default
        field.drawsBackground = false   // the SwiftUI background provides contrast
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        if let label = accessibilityLabel {
            field.setAccessibilityLabel(label)
        }
        Task { @MainActor [weak field] in
            guard let field, field.window != nil else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: FocusSelectTextField, context: Context) {
        // Do not overwrite stringValue here: that would clobber the user's edits.
        field.font = font
        field.textColor = textColor
        // Keep coordinator closures current in case the caller re-renders with new
        // captures (e.g., a closure that closes over an @State value).
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        // Store only the closures, not the parent struct. The parent is a value
        // type (struct), so holding it directly would copy its closure properties
        // anyway; keeping just the closures is explicit about what the Coordinator
        // actually needs and avoids any latent issue if the struct ever gains a
        // reference-type stored property that a caller captures. `var` so
        // updateNSView can refresh them if the caller provides new closures.
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        /// True once Return or Esc handled the edit, so the end-editing
        /// notification that follows does not commit a second time.
        private var resolved = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                resolved = true
                onCommit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                resolved = true
                onCancel()
                return true
            default:
                return false
            }
        }

        // Clicking elsewhere ends editing without Return: commit what is there.
        func controlTextDidEndEditing(_ note: Notification) {
            guard !resolved, let field = note.object as? NSTextField else { return }
            resolved = true
            onCommit(field.stringValue)
        }
    }
}

/// NSTextField that selects its whole contents the first time it gains focus.
final class FocusSelectTextField: NSTextField {
    private var didInitialSelect = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, !didInitialSelect {
            didInitialSelect = true
            currentEditor()?.selectAll(nil)
        }
        return became
    }
}
