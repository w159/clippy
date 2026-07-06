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

/// Clip editors live in normal activating windows (unlike the panel): editing
/// is a deliberate action where stealing focus is fine. Each clip gets its own
/// window; windows share a tabbing identifier and are explicitly tabbed
/// together, so concurrent edits present as native macOS window tabs. Opening
/// a clip that is already being edited focuses its existing window/tab.
final class EditorWindowController: NSObject, NSWindowDelegate {
    /// One live editor: its window, the dirty-state bridge for close prompts,
    /// and the edited clip's id (nil ids never coalesce onto the same window).
    private struct Session {
        let window: NSWindow
        let bridge: EditorDirtyStateBridge
        let clipID: Int64?
    }

    private var sessions: [Session] = []

    /// Shared tab group for all clip editors.
    private static let tabbingIdentifier = "com.clippy.editor"

    func open(clip: Clip, store: ClipStore) {
        // Re-opening a clip that already has an editor focuses it instead of
        // spawning a duplicate window over the same row.
        if let id = clip.id, let existing = sessions.first(where: { $0.clipID == id }) {
            NSApp.activate()
            existing.window.makeKeyAndOrderFront(nil)
            return
        }

        let bridge = EditorDirtyStateBridge()
        let isImage = clip.contentKind == .image
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: isImage ? 640 : 560, height: isImage ? 540 : 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Per-clip titles so tabs are tellable apart; displayTitle falls back
        // to the source app name when the user has not named the clip.
        window.title = clip.displayTitle.isEmpty
            ? (isImage ? "Edit Image" : "Edit Clip")
            : clip.displayTitle
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier

        let editor = ClipEditorView(clip: clip, store: store, dirtyBridge: bridge, onClose: { [weak self, weak window] in
            guard let self, let window else { return }
            self.close(window)
        })
        window.contentView = NSHostingView(rootView: editor)
        window.delegate = self

        // Tab into the newest existing editor; a lone editor centers instead.
        if let host = sessions.last?.window, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        sessions.append(Session(window: window, bridge: bridge, clipID: clip.id))

        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close(_ window: NSWindow) {
        window.delegate = nil
        window.orderOut(nil)
        sessions.removeAll { $0.window === window }
    }

    // MARK: - NSWindowDelegate

    /// The red close button routes here. A clean editor closes immediately; a
    /// dirty one prompts Save / Discard / Keep Editing so edits are never
    /// silently thrown away.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session = sessions.first(where: { $0.window === sender }),
              session.bridge.isDirty()
        else { return true }

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
            return session.bridge.save()
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
        guard let window = notification.object as? NSWindow else { return }
        sessions.removeAll { $0.window === window }
    }
}
