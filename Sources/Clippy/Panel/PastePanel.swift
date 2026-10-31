import AppKit

/// Borderless, nonactivating floating panel. It can take keyboard focus for
/// the search field without activating Clippy, so the frontmost app keeps
/// its active state and receives the simulated Cmd-V after selection.
final class PastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// `.titled` + `.fullSizeContentView` makes AppKit supply the resize edges and
    /// cursors (PNL-02); the titlebar is then hidden so the SwiftUI glass content
    /// fills the whole window. `.nonactivatingPanel` keeps the frontmost app active.
    static let chromeStyleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable]

    /// Hides the titlebar and traffic lights and makes the window movable by its
    /// header drag region only (PNL-01), with a clear, shadowed glass backdrop.
    func applyChrome() {
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    /// The panel's search field: the editable text field whose accessibility
    /// label or placeholder is "Search clips". Other editable fields can share the
    /// window (assistant prompt, command palette), so when neither identifies the
    /// search field the one nearest the top of the window wins, which is the
    /// header search bar.
    static func searchField(in root: NSView) -> NSTextField? {
        var fields: [NSTextField] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(root)
        func isSearch(_ field: NSTextField) -> Bool {
            let label = field.accessibilityLabel() ?? ""
            let placeholder = field.placeholderAttributedString?.string ?? field.placeholderString ?? ""
            return label == "Search clips" || placeholder == "Search clips"
        }
        if let named = fields.first(where: isSearch) { return named }
        return fields.max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }
    }

    /// Types `characters` into the search field through its field editor, in the
    /// same call as the key event. Every character then takes the text system's
    /// own path (the editor edits, SwiftUI's binding follows), so nothing races
    /// the binding sync the way a store write plus a later focus change did.
    /// False when the field or its editor cannot be reached; the caller then
    /// falls back to writing the query itself.
    func insertIntoSearchField(_ characters: String) -> Bool {
        guard let root = contentView, let field = Self.searchField(in: root) else { return false }
        var editor = firstResponder as? NSTextView
        if editor?.delegate as? NSTextField !== field {
            guard makeFirstResponder(field) else { return false }
            editor = firstResponder as? NSTextView ?? fieldEditor(false, for: field) as? NSTextView
        }
        guard let editor else { return false }
        // Becoming first responder selects the whole text; typing would replace it.
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        editor.insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// Bound by PanelController so Escape routes through hide() (which saves the
    /// panel origin and remembered size) instead of a bare orderOut(nil) that
    /// would discard them.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        let settings = AppSettings.shared
        // Pinned panel ignores all auto-hide triggers, including Escape.
        guard !settings.panelPinned, settings.hideOnEscape else { return }
        if let onCancel {
            onCancel()
        } else {
            orderOut(nil)
        }
    }
}
