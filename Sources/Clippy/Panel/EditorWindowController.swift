import AppKit
import SwiftUI

/// Bridges the AppKit window to the SwiftUI editor's state. The editor
/// registers its callbacks in onAppear; the window controller consults them
/// from windowShouldClose (dirty prompt), at quit (draft autosave), and pushes
/// title changes back to the window.
@MainActor
final class EditorDirtyStateBridge {
    /// True when the editor holds unsaved changes.
    var isDirty: () -> Bool = { false }
    /// Attempt to persist the edits; `completion(true)` means the window may
    /// close. May complete asynchronously (image saves run off the main thread).
    var save: (@escaping (Bool) -> Void) -> Void = { $0(true) }
    /// The unsaved text state for crash/quit recovery; nil when clean or when
    /// the editor cannot draft (image editors).
    var draft: () -> EditorDraft? = { nil }
    /// True for image editors, which are prompted at quit rather than drafted.
    var isImage = false
    /// The clip's display title changed (rename or reload); update the window.
    var onTitleChange: (String) -> Void = { _ in }
    /// The dirty state changed; the window mirrors it in its close-button dot (NSWindow.isDocumentEdited).
    var onDirtyChange: (Bool) -> Void = { _ in }
}

/// Clip editors live in normal activating windows (unlike the panel): editing
/// is a deliberate action where stealing focus is fine. Each clip gets its own
/// untabbed window that cascades from the previous one. Opening
/// a clip that is already being edited focuses its existing window/tab.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    /// One live editor: its window, the bridge, the edited clip's id (nil ids
    /// never coalesce onto the same window), and the window's own find text.
    private final class Session {
        let window: NSWindow
        let bridge: EditorDirtyStateBridge
        let clipID: Int64?
        var findString = ""

        init(window: NSWindow, bridge: EditorDirtyStateBridge, clipID: Int64?) {
            self.window = window
            self.bridge = bridge
            self.clipID = clipID
        }
    }

    private var sessions: [Session] = []

    /// Called just before an editor window is shown, so the app can get the
    /// always-on-top panel out of the way (PNL-07).
    var onWillOpen: (() -> Void)?

    /// Set by the app once termination has been accepted: closing windows
    /// during quit must keep the drafts the quit path just wrote.
    var isTerminating = false

    /// Window title for a clip: its display title, else a per-kind fallback.
    static func windowTitle(for clip: Clip) -> String {
        let title = clip.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return clip.contentKind == .image ? "Edit Image" : "Edit Clip"
    }

    // MARK: - Opening

    /// Opens (or focuses) the editor for `clip`. `draft` restores unsaved text
    /// recovered from a previous session.
    func open(clip: Clip, store: ClipStore, draft: EditorDraft? = nil) {
        // Re-opening a clip that already has an editor focuses it instead of
        // spawning a duplicate window over the same row.
        if let id = clip.id, let existing = sessions.first(where: { $0.clipID == id }) {
            onWillOpen?()
            NSApp.activate()
            existing.window.makeKeyAndOrderFront(nil)
            return
        }

        let bridge = EditorDirtyStateBridge()
        let isImage = clip.contentKind == .image
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: isImage ? 720 : 640, height: isImage ? 580 : 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: clip)
        window.isReleasedWhenClosed = false
        // Each clip is its own window; native tabbing is off so tab-group state never lingers.
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: isImage ? 460 : 380)
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        // Frame autosave per clip kind: text and image editors remember their own size.
        window.setFrameAutosaveName(isImage ? "ClippyImageEditorWindow" : "ClippyTextEditorWindow")
        bridge.onDirtyChange = { [weak window] dirty in window?.isDocumentEdited = dirty }
        bridge.onTitleChange = { [weak window] title in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            window?.title = trimmed.isEmpty ? (isImage ? "Edit Image" : "Edit Clip") : trimmed
        }

        let editor = ClipEditorView(clip: clip, store: store, dirtyBridge: bridge, draft: draft, onClose: { [weak self, weak window] in
            guard let self, let window else { return }
            self.close(window)
        })
        window.contentView = NSHostingView(rootView: editor)
        window.delegate = self

        // Cascade from the newest editor; the first window restores its autosaved frame or centers.
        if let host = sessions.last?.window, host.isVisible {
            window.cascadeTopLeft(from: NSPoint(x: host.frame.minX, y: host.frame.maxY))
        } else if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        sessions.append(Session(window: window, bridge: bridge, clipID: clip.id))

        onWillOpen?()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Reopens editors for drafts left by a previous run (quit or crash with
    /// unsaved edits). Drafts whose clip no longer exists are dropped.
    func recoverDrafts(store: ClipStore) {
        for draft in EditorDraftStore.shared.all() {
            guard let clip = ClipEditorPersistence.live.fetch(id: draft.clipID),
                  clip.contentKind == .text else {
                EditorDraftStore.shared.remove(clipID: draft.clipID)
                continue
            }
            open(clip: clip, store: store, draft: draft)
        }
    }

    /// `window.close()` skips windowShouldClose, so this is the unconditional
    /// close used after the editor (or the sheet) has already resolved edits.
    private func close(_ window: NSWindow) {
        window.close()
    }

    // MARK: - Quit support (EDT-01)

    /// Whether any open text editor holds unsaved edits.
    var hasDirtyTextEditors: Bool {
        sessions.contains { !$0.bridge.isImage && $0.bridge.isDirty() }
    }

    /// Whether any open image editor holds unsaved edits.
    var hasDirtyImageEditors: Bool {
        sessions.contains { $0.bridge.isImage && $0.bridge.isDirty() }
    }

    /// Writes a draft for every dirty text editor. Returns false when a write
    /// failed, so the caller can fall back to prompting.
    @discardableResult
    func autosaveDrafts() -> Bool {
        let drafts = sessions.compactMap { $0.bridge.draft() }
        guard !drafts.isEmpty else { return true }
        return EditorDraftStore.shared.save(drafts)
    }

    // MARK: - NSWindowDelegate

    /// The red close button routes here. A clean editor closes immediately; a
    /// dirty one shows a sheet-modal Save / Discard / Keep Editing prompt on
    /// the window, so edits are never silently thrown away and other windows
    /// stay usable.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session = sessions.first(where: { $0.window === sender }),
              session.bridge.isDirty()
        else { return true }
        guard sender.attachedSheet == nil else { return false }

        let alert = NSAlert()
        alert.messageText = "Save changes to this clip?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            switch response {
            case .alertFirstButtonReturn:
                // Only close if the save actually landed; on failure the editor
                // stays open and shows the error inline.
                session.bridge.save { saved in
                    if saved { self.close(sender) }
                }
            case .alertSecondButtonReturn:
                self.close(sender)
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let session = sessions.first(where: { $0.window === window }) else { return }
        sessions.removeAll { $0 === session }
        if let id = session.clipID {
            // Saved or discarded: the draft is stale. During quit it is the
            // only copy of the user's edits, so keep it.
            if !isTerminating { EditorDraftStore.shared.remove(clipID: id) }
            // The external-editor session belongs to this editor window.
            MainActor.assumeIsolated { ExternalEditorService.shared.closeSession(clipID: id) }
        }
        // Release the hosted SwiftUI tree now so its observation and timers stop.
        window.delegate = nil
        window.contentView = nil
    }

    // Per-window find text (EDT-10): the find bar shares one system pasteboard,
    // so each window saves its term when it loses key and restores it (empty
    // for a new window) when it becomes key again.

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let session = sessions.first(where: { $0.window === window }) else { return }
        Self.setFindString(session.findString)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let session = sessions.first(where: { $0.window === window }) else { return }
        session.findString = Self.findString()
    }

    private static func findString() -> String {
        NSPasteboard(name: .find).string(forType: .string) ?? ""
    }

    private static func setFindString(_ value: String) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        if !value.isEmpty { pasteboard.setString(value, forType: .string) }
    }
}
