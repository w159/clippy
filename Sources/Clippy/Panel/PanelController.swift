import AppKit
import Combine
import SwiftUI

/// Owns the popup panel: creates it, positions it per the user's position
/// mode (caret, mouse, last position, screen center), shows and hides it.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let store: ClipStore
    let settings = AppSettings.shared
    var panel: PastePanel?

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

    let displayMemory = PanelDisplayMemory()
    private var screenObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    /// PNL-07: observes other Clippy windows taking key status to drop the panel level.
    var keyObserver: NSObjectProtocol?
    var lockCancellable: AnyCancellable?
    /// True while the panel's content is the lock view rather than the clip list.
    var showsLockView = false
    private var panelInteractionGeneration = 0
    private var interactionMonitor: Any?

    init(store: ClipStore) {
        self.store = store
        super.init()
        // PNL-06: re-clamp and prune remembered origins when displays change.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screenParametersChanged() } }
        observeOtherWindows()
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, self.isVisible, event.windowNumber == self.panel?.windowNumber else { return event }
            self.panelInteractionGeneration &+= 1
            return event
        }
        // PNL-04: a request to focus the search field while locked means "unlock".
        focusObserver = NotificationCenter.default.addObserver(
            forName: .clippyFocusPanelSearch, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.showsLockView else { return }
                AppLock.shared.unlock()
            }
        }
    }

    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        panelInteractionGeneration &+= 1
        // Smart Suggestions: capture the frontmost app's context BEFORE the
        // panel takes key status or orders in. Runs off-main; screen text
        // stays in memory and is dropped in hide().
        captureSuggestionContext()

        // OCR-02: the warm-up policy decides whether Vision needs warming
        // (image clips visible, rate-limited); the panel only reports the open.
        OCRWarmupPolicy.shared.panelDidShow()
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
        // PNL-03: a saved or default size below the layout minimum is clamped up.
        let size = clampedPanelSize(in: panel)

        // Fresh root view per presentation: resets search text, selection,
        // and guarantees the search field grabs focus. While the app lock is
        // engaged the clip list is replaced by a LockView (SEC-06); it is
        // swapped back as soon as the user authenticates.
        store.query = ""
        let locked = AppLock.shared.panelWillShow()
        installContent(in: panel, locked: locked)
        observeLockState()
        panel.appearance = Theme.nsAppearance(settings)

        // PNL-05: place the panel immediately from the configured fast fallback.
        // Caret mode can refine this asynchronously only when the result is close
        // enough to avoid a visible jump and the user has not interacted.
        let initialMouse = NSEvent.mouseLocation
        let initialFrame = fastFrame(size: size)
        let interactionAtShow = panelInteractionGeneration
        panel.setFrame(initialFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        if settings.positionMode == .caret {
            // AX can block in another process. Let the panel appear now, then
            // query the app that had focus before Clippy's panel took focus.
            let targetProcessID = previousApp?.processIdentifier
            Task.detached(priority: .userInitiated) { [weak self, weak panel] in
                guard let caret = CaretLocator.caretScreenRect(applicationPID: targetProcessID) else { return }
                await MainActor.run { [weak self, weak panel] in
                    guard let self, let panel, panel.isVisible else { return }
                    let target = self.frame(anchoredTo: caret, size: panel.frame.size)
                    let currentMouse = NSEvent.mouseLocation
                    let unchanged = self.panelInteractionGeneration == interactionAtShow
                    guard Self.shouldApplyCaretPlacement(
                        initialFrame: initialFrame, caretFrame: target,
                        initialMouse: initialMouse, currentMouse: currentMouse,
                        interactionUnchanged: unchanged
                    ) else { return }
                    panel.setFrame(target, display: true, animate: false)
                }
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        settings.lastPanelOrigin = panel.frame.origin
        if let screen = panel.screen ?? screenContaining(rect: panel.frame),
           let display = PanelDisplayMemory.displayID(of: screen) {
            displayMemory.save(origin: panel.frame.origin, for: display)
        }
        if settings.rememberPanelSize {
            settings.panelWidth = panel.frame.width
            settings.panelHeight = panel.frame.height
        }
        panel.orderOut(nil)
        // Privacy: drop screen-derived context when the panel closes.
        store.clearSuggestions()
    }

    /// Kicks off an off-main Accessibility read of the frontmost app and feeds
    /// the result to the store. No-op (and clears state) when the feature is off.
    private func captureSuggestionContext() {
        guard settings.suggestionsEnabled else {
            store.clearSuggestions()
            return
        }
        let ignored = Set(settings.ignoredBundleIDs)
        let maxChars = settings.suggestionsUseWindowText ? 1500 : 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ctx = ContextReader.capture(ignoredBundleIDs: ignored, maxChars: maxChars)
            DispatchQueue.main.async { self?.store.refreshSuggestions(context: ctx) }
        }
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
        // PNL-08: cooperative activation (macOS 14+). Yield to the target, then
        // activate it on our behalf; `.activateAllWindows` brings its windows
        // forward reliably.
        NSApp.yieldActivation(to: previousApp)
        _ = previousApp.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
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

}
