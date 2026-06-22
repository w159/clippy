import AppKit
import SwiftUI

/// The clip editor lives in a normal activating window (unlike the panel):
/// editing is a deliberate action where stealing focus is fine.
final class EditorWindowController {
    private var window: NSWindow?

    func open(clip: Clip, store: ClipStore) {
        // Close and release any existing editor window before creating a new
        // one. The previous implementation unconditionally reassigned
        // self.window, dropping the prior NSWindow without orderOut/close,
        // which leaked it (isReleasedWhenClosed=false means AppKit will not
        // release it on its own).
        if let existing = window {
            existing.orderOut(nil)
            window = nil
        }

        let editor = ClipEditorView(clip: clip, store: store, onClose: { [weak self] in
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
        window.center()
        self.window = window

        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }
}
