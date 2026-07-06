import AppKit
import SwiftUI

/// Bridges the AppKit window's close button to the SwiftUI editor's dirty
/// state. The editor registers its callbacks in onAppear; the window
/// controller consults them from windowShouldClose so closing a dirty editor
/// prompts instead of silently discarding edits.
final class EditorDirtyStateBridge {
    /// True when the editor holds unsaved changes.
    var isDirty: () -> Bool = { false }
    /// Attempt to persist the edits. Returns true on success (window may close).
    var save: () -> Bool = { true }
}

/// The clip editor lives in a normal activating window (unlike the panel):
/// editing is a deliberate action where stealing focus is fine.
final class EditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var bridge: EditorDirtyStateBridge?

    func open(clip: Clip, store: ClipStore) {
        // Close and release any existing editor window before creating a new
        // one. The previous implementation unconditionally reassigned
        // self.window, dropping the prior NSWindow without orderOut/close,
        // which leaked it (isReleasedWhenClosed=false means AppKit will not
        // release it on its own).
        if let existing = window {
            existing.delegate = nil
            existing.orderOut(nil)
            window = nil
        }

        let bridge = EditorDirtyStateBridge()
        self.bridge = bridge
        let editor = ClipEditorView(clip: clip, store: store, dirtyBridge: bridge, onClose: { [weak self] in
            self?.close()
        })

        let isImage = clip.contentKind == .image
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: isImage ? 640 : 560, height: isImage ? 540 : 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = isImage ? "Edit Image" : "Edit Clip"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor)
        window.delegate = self
        window.center()
        self.window = window

        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        bridge = nil
    }

    // MARK: - NSWindowDelegate

    /// The red close button routes here. A clean editor closes immediately; a
    /// dirty one prompts Save / Discard / Keep Editing so edits are never
    /// silently thrown away.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let bridge, bridge.isDirty() else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to this clip?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Only close if the save actually landed; on failure the editor
            // stays open and shows the error inline.
            return bridge.save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Close came from the title bar rather than Cancel/Save; drop our
        // strong reference so the window (isReleasedWhenClosed=false) and the
        // hosted SwiftUI tree are released.
        window = nil
        bridge = nil
    }
}
