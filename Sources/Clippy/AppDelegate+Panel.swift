import AppKit
import Darwin
import Sparkle
import SwiftUI

extension AppDelegate {
    /// Wires the panel action callbacks. Factored out so the recovery Retry
    /// path can invoke it after a late database open without duplicating the
    /// large callback block from applicationDidFinishLaunching.
    func wirePanelCallbacks() {
        panelController.onPaste = { [weak self] clip, asPlainText in
            guard let self else { return }
            let settings = AppSettings.shared
            if settings.hideAfterPaste && !settings.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            self.pasteService.paste(clip, asPlainText: asPlainText)
        }
        panelController.onPasteMany = { [weak self] clips, combined, asPlainText in
            guard let self else { return }
            let settings = AppSettings.shared
            if settings.hideAfterPaste && !settings.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            if combined {
                self.pasteService.pasteCombined(clips, asPlainText: asPlainText)
            } else {
                self.pasteService.pasteSequence(clips, asPlainText: asPlainText)
            }
        }
        panelController.onPasteFile = { [weak self] clip, move in
            guard let self else { return }
            let settings = AppSettings.shared
            if settings.hideAfterPaste && !settings.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            self.pasteService.pasteFile(clip, move: move)
        }
        panelController.onPrimary = { [weak self] clip in
            guard let self else { return }
            let settings = AppSettings.shared
            if settings.hideAfterPaste && !settings.panelPinned { self.panelController.hide() }
            if settings.clickCopyOnly {
                self.pasteService.copy(clip, asPlainText: settings.pastePlainTextByDefault)
            } else {
                self.panelController.restoreFocusToPreviousApp()
                self.pasteService.paste(clip, asPlainText: settings.pastePlainTextByDefault)
            }
        }
        panelController.onSendKeystrokes = { [weak self] clip in
            guard let self else { return }
            let settings = AppSettings.shared
            if settings.hideAfterPaste && !settings.panelPinned { self.panelController.hide() }
            self.panelController.restoreFocusToPreviousApp()
            self.pasteService.copy(clip, asPlainText: true)
            let text = clip.contentText
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.keystrokeService.type(text)
            }
        }
        panelController.onEdit = { [weak self] clip in
            guard let self else { return }
            self.editorController.open(clip: clip, store: self.store)
        }
        panelController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
    }

    // MARK: - Actions

    @objc func openPanel() {
        // Re-opening a visible panel must not rebuild it (that resets the
        // query, selection, and scroll): ask it to focus its search field.
        if panelController.isVisible {
            NotificationCenter.default.post(name: .clippyFocusPanelSearch, object: nil)
            return
        }
        panelController.show()
    }

    @objc func openSettings() {
        // The panel floats above normal windows; hide it so Settings is not
        // opened behind it (PNL-07).
        panelController.hide()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Clippy Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }
        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All unpinned clips will be deleted. Pinned clips are kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            try? database.deleteUnclassifiedClips()
            // Bulk delete bypasses the per-clip hook, so drop the Spotlight donations too.
            ClipSpotlightIndexer.removeAll()
        }
    }

    // MARK: - Hotkeys

    /// Binds the named global hotkeys to their actions and registers stored chords.
    func configureHotKeys() {
        let center = HotKeyCenter.shared
        center.handlers[.showPanel] = { [weak self] in self?.panelController.toggle() }
        center.handlers[.pastePlain] = { [weak self] in
            self?.pasteRecent(offset: 0, asPlainText: true, route: .pastePlainHotkey)
        }
        center.handlers[.pastePrevious] = { [weak self] in self?.pasteRecent(offset: 1, asPlainText: false) }
        center.handlers[.pasteStackNext] = {
            NotificationCenter.default.post(name: .clippyPasteStackPasteNext, object: nil)
        }
        center.handlers[.pasteStackToggle] = {
            NotificationCenter.default.post(name: .clippyPasteStackToggle, object: nil)
        }
        center.registerAll()
    }

    /// Pastes the clip at `offset` (0 = newest) into the frontmost app.
    /// `route` selects the per-app paste-profile rule (the paste-plain hotkey is always plain).
    func pasteRecent(offset: Int, asPlainText: Bool, route: PasteRoute = .paste) {
        guard !(AppLock.shared.isEnabled && AppLock.shared.isLocked),
              let clips = try? database.recentClips(limit: offset + 1), clips.count > offset else { return }
        let settings = AppSettings.shared
        if settings.hideAfterPaste && !settings.panelPinned { panelController.hide() }
        panelController.restoreFocusToPreviousApp()
        pasteService.paste(clips[offset], asPlainText: asPlainText, route: route)
    }
}

