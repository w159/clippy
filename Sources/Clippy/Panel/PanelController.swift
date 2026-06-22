import AppKit
import SwiftUI

/// Owns the popup panel: creates it, positions it per the user's position
/// mode (caret, mouse, last position, screen center), shows and hides it.
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipStore
    private let settings = AppSettings.shared
    private var panel: PastePanel?

    var onPaste: ((Clip, Bool) -> Void)?
    /// Paste several clips. `combined == true` joins them into one paste;
    /// false pastes them sequentially.
    var onPasteMany: (([Clip], _ combined: Bool, _ asPlainText: Bool) -> Void)?
    /// Paste a file clip. move == true moves (Cmd+Option+V), false copies (Cmd+V).
    var onPasteFile: ((Clip, _ move: Bool) -> Void)?
    var onPrimary: ((Clip) -> Void)?
    var onSendKeystrokes: ((Clip) -> Void)?
    var onEdit: ((Clip) -> Void)?
    var onOpenSettings: (() -> Void)?

    /// The app that was frontmost when the panel last opened. Synthetic paste
    /// and keystroke events need that app's text field to be the first responder;
    /// re-activating it before sending restores focus the panel briefly took.
    private(set) var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: ClipStore) {
        self.store = store
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // Remember who had focus before the panel grabs key status, so the send
        // paths can hand keyboard focus back to that app. Skip Clippy itself
        // (e.g. when the panel is re-shown while already frontmost).
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        let panel = ensurePanel()
        // Re-apply level/float each show in case the user changed the setting
        // since the panel was last created.
        applyFloatLevel(to: panel)
        let size = NSSize(width: settings.panelWidth, height: settings.panelHeight)

        // Fresh root view per presentation: resets search text, selection,
        // and guarantees the search field grabs focus.
        store.query = ""
        let root = ClipListView(
            store: store,
            onPaste: { [weak self] clip, asPlainText in self?.onPaste?(clip, asPlainText) },
            onPasteMany: { [weak self] clips, combined, asPlainText in
                self?.onPasteMany?(clips, combined, asPlainText)
            },
            onPasteFile: { [weak self] clip, move in self?.onPasteFile?(clip, move) },
            onPrimary: { [weak self] clip in self?.onPrimary?(clip) },
            onSendKeystrokes: { [weak self] clip in self?.onSendKeystrokes?(clip) },
            onEdit: { [weak self] clip in self?.onEdit?(clip) },
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                // Settings opens alongside the panel; panel stays visible.
                self?.onOpenSettings?()
            }
        )
        panel.appearance = Theme.nsAppearance(settings)
        panel.contentView = NSHostingView(rootView: root)

        // Position synchronously using the last-known or mouse anchor so the
        // panel appears immediately. For caret mode, refine the position on a
        // background thread to avoid blocking the main thread on the AX API.
        let initialFrame = fastFrame(size: size)
        panel.setFrame(initialFrame, display: false)
        panel.makeKeyAndOrderFront(nil)

        if settings.positionMode == .caret {
            repositionAtCaretAsync(panel: panel, size: size)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        settings.lastPanelOrigin = panel.frame.origin
        if settings.rememberPanelSize {
            settings.panelWidth = panel.frame.width
            settings.panelHeight = panel.frame.height
        }
        panel.orderOut(nil)
    }

    /// Hand keyboard focus back to the app that was frontmost when the panel
    /// opened. The panel is a nonactivating key window; after it orders out the
    /// target window does not always reclaim first responder on its own, so
    /// synthetic key events would otherwise land nowhere and beep. Re-activating
    /// the app forces its text field back to first responder before we type.
    func restoreFocusToPreviousApp() {
        // Re-resolve the target each time: a long-lived panel may hold a stale
        // previousApp (captured only at show()), and a nonactivating panel does
        // not steal frontmost, so the live frontmost is still the app we want to
        // send into. Prefer it when it is a real, running, non-Clippy app.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           !front.isTerminated {
            previousApp = front
        }
        guard let previousApp,
              previousApp.bundleIdentifier != Bundle.main.bundleIdentifier,
              !previousApp.isTerminated else { return }
        // activate(options:) replaces the deprecated no-arg activate(); the
        // options set brings the app's windows forward reliably.
        previousApp.activate(options: [.activateAllWindows])
    }

    /// Debug aid for UI smoke tests: render the panel's content into a PNG.
    /// Works even when the panel lost key status, since it draws the view
    /// hierarchy directly instead of capturing the screen.
    func snapshotPanel(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // hideOnClickAway opt-in: hide when focus moves to another app.
        // panelPinned suppresses all auto-hide triggers, including this one.
        // Default (hideOnClickAway=false) preserves the original persistent behavior.
        guard settings.hideOnClickAway, !settings.panelPinned else { return }
        // Opening a Clippy-owned window (Settings, editor) from the panel takes
        // key away from the panel. Treat that as same-app focus and keep the
        // panel visible, instead of dismissing it contrary to intent.
        if let key = NSApp.keyWindow, key !== (panel as NSWindow?) {
            return
        }
        hide()
    }

    // MARK: - Construction and placement

    /// Applies the user's panelFloatLevel preference to a panel instance.
    /// alwaysOnTop: .statusBar (25) + isFloatingPanel — the original behavior, floats
    ///   above every normal app window and full-screen chrome.
    /// aboveNormalWindows: .floating + isFloatingPanel — above normal windows, but
    ///   below status bar and menu extras.
    /// normalOrder: .normal + not floating — participates in standard z-order.
    private func applyFloatLevel(to panel: PastePanel) {
        switch settings.panelFloatLevel {
        case .alwaysOnTop:
            panel.level = .statusBar
            panel.isFloatingPanel = true
        case .aboveNormalWindows:
            panel.level = .floating
            panel.isFloatingPanel = true
        case .normalOrder:
            panel.level = .normal
            panel.isFloatingPanel = false
        }
    }

    private func ensurePanel() -> PastePanel {
        if let panel { return panel }
        let panel = PastePanel(
            contentRect: NSRect(x: 0, y: 0, width: settings.panelWidth, height: settings.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        // Level and float behavior are applied per-show so live changes to
        // panelFloatLevel take effect the next time the panel opens.
        applyFloatLevel(to: panel)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 280, height: 240)
        // .canJoinAllSpaces: stays visible across space switches.
        // .fullScreenAuxiliary: renders over full-screen apps.
        // .managed (not .transient): the window manager keeps it in the current
        //   space instead of evicting it during Mission Control transitions.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        // Route Escape through hide() so the origin and remembered size are
        // preserved (cancelOperation used to orderOut(nil) and skip the save).
        panel.onCancel = { [weak self] in self?.hide() }
        self.panel = panel
        return panel
    }

    /// Synchronous frame that never calls the AX API, safe to call on the main
    /// thread with no risk of blocking. For caret mode it uses the mouse as the
    /// initial anchor; repositionAtCaretAsync() refines it once the AX result
    /// arrives on a background thread.
    private func fastFrame(size: NSSize) -> NSRect {
        switch settings.positionMode {
        case .caret:
            // Use mouse as a cheap stand-in; async refinement follows immediately.
            return frame(anchoredTo: mouseAnchor(), size: size)
        case .mouse:
            return frame(anchoredTo: mouseAnchor(), size: size)
        case .lastPosition:
            if let origin = settings.lastPanelOrigin {
                return clamped(NSRect(origin: origin, size: size))
            }
            return centeredFrame(size: size)
        case .screenCenter:
            return centeredFrame(size: size)
        }
    }

    /// Looks up the caret rect on a background thread (AX can block) and
    /// moves the panel if the result differs meaningfully from its current
    /// position. No-ops if the panel was closed before the lookup returns.
    private func repositionAtCaretAsync(panel: PastePanel, size: NSSize) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak panel] in
            guard let self else { return }
            let caretRect = CaretLocator.caretScreenRect()
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, panel.isVisible else { return }
                let target: NSRect
                if let caret = caretRect {
                    target = self.frame(anchoredTo: caret, size: size)
                } else {
                    // AX unavailable or app blocked it; mouse anchor already set.
                    return
                }
                // Only animate if the delta is visible to the user (> 4pt).
                if abs(target.origin.x - panel.frame.origin.x) > 4
                    || abs(target.origin.y - panel.frame.origin.y) > 4 {
                    panel.setFrame(target, display: true, animate: false)
                }
            }
        }
    }

    private func mouseAnchor() -> CGRect {
        let location = NSEvent.mouseLocation
        return CGRect(x: location.x, y: location.y, width: 0, height: 0)
    }

    /// Place the panel just below the anchor rect; flip above it when there
    /// is no room, and keep everything inside the screen's visible frame.
    private func frame(anchoredTo anchor: CGRect, size: NSSize) -> NSRect {
        let visible = screen(containing: anchor.origin).visibleFrame
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - 6 - size.height)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 6
        }
        return clamped(NSRect(origin: origin, size: size), within: visible)
    }

    private func centeredFrame(size: NSSize) -> NSRect {
        let visible = screen(containing: NSEvent.mouseLocation).visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ rect: NSRect, within visible: NSRect? = nil) -> NSRect {
        let bounds = visible ?? screen(containing: rect.origin).visibleFrame
        var result = rect
        result.origin.x = max(bounds.minX + 8, min(result.origin.x, bounds.maxX - result.width - 8))
        result.origin.y = max(bounds.minY + 8, min(result.origin.y, bounds.maxY - result.height - 8))
        return result
    }

    private func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen.main!
    }
}
