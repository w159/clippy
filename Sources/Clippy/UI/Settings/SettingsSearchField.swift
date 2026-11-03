import AppKit
import SwiftUI

/// The settings sidebar search field, backed by a plain `NSSearchField`.
///
/// SwiftUI's `.searchable` and `List` key routing did not receive Up, Down, Return or Esc on
/// macOS CI when key events arrive through `NSWindow.sendEvent`. An AppKit field with its own
/// delegate gets those commands as `doCommandBy` selectors, so the keyboard works the same way
/// for a person at the keys and for the harness.
struct SettingsSearchField: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("ClippySettingsSearchField")

    @Binding var text: String
    /// Bump to move keyboard focus into the field.
    let focusToken: Int
    let onMove: (MoveCommandDirection) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.identifier = Self.identifier
        field.placeholderString = "Search settings"
        field.setAccessibilityLabel("Search settings")
        field.sendsSearchStringImmediately = true
        field.controlSize = .regular
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            Task { @MainActor [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField
        var lastFocusToken: Int

        init(_ parent: SettingsSearchField) {
            self.parent = parent
            lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(.down)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
