import AppKit
import Combine
import Sparkle

extension AppDelegate {
    // MARK: - Status item

    /// Creates the status item. Clicks are handled by `statusItemClicked(_:)`, which
    /// toggles the panel on left click and pops the menu on right click (or on any
    /// click when `StatusItemPreferences.clickBehavior` is `.menuOnAnyClick`).
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.wantsLayer = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon()

        // Bounce the icon the instant a clip is captured, in sync with the
        // capture sound (both fire off the same .clippyDidCapture event).
        NotificationCenter.default.addObserver(forName: .clippyDidCapture, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let button = self?.statusItem.button else { return }
                StatusBarIcon.bounce(button)
            }
        }
        // The icon shows the locked state too.
        AppLock.shared.$isLocked.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusIcon()
        }.store(in: &statusIconObservers)
        // The badge shows how many items remain in the paste stack (FEAT-06).
        PasteStack.shared.$items.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusIcon()
        }.store(in: &statusIconObservers)
    }

    /// Current icon state: locked beats paused beats capturing.
    var statusIconState: StatusBarIcon.State {
        if AppLock.shared.isEnabled && AppLock.shared.isLocked { return .locked }
        return monitor.isPaused ? .paused : .capturing
    }

    /// Refreshes the icon, tooltip and VoiceOver label for the current state.
    func updateStatusIcon() {
        let state = statusIconState
        statusItem.button?.image = StatusBarIcon.image(state: state)
        let stackCount = PasteStack.shared.count
        let label = StatusBarIcon.accessibilityLabel(state: state, stackCount: stackCount)
        statusItem.button?.title = StatusBarIcon.badgeTitle(stackCount: stackCount)
        statusItem.button?.imagePosition = stackCount > 0 ? .imageLeading : .imageOnly
        statusItem.length = stackCount > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    /// Left click toggles the panel; right click or Control-click opens the menu.
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || StatusItemPreferences.clickBehavior == .menuOnAnyClick
        if wantsMenu { popUpStatusMenu() } else { panelController.toggle() }
    }

    /// Builds a fresh menu (recent clips change constantly) and shows it under the icon.
    func popUpStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = buildStatusMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    /// The menu: Open, recent clips, Pause, Settings and the rest.
    func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Clippy", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        addRecentClips(to: menu)

        let pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = monitor.isPaused ? .on : .off
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let clearItem = NSMenuItem(title: "Clear Unpinned History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        // Stored scripts, runnable straight from the menu bar; rebuilt each time it opens.
        let scriptsItem = NSMenuItem(title: "Run Script", action: nil, keyEquivalent: "")
        scriptsMenu.delegate = self
        scriptsItem.submenu = scriptsMenu
        menu.addItem(scriptsItem)
        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Quit Clippy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// Inserts the last clips (sensitive ones omitted, titles truncated) after a header.
    /// Hidden entirely while the app lock is engaged so history is never exposed.
    private func addRecentClips(to menu: NSMenu) {
        guard !(AppLock.shared.isEnabled && AppLock.shared.isLocked) else { return }
        let pageSize = StatusItemMenuModel.defaultLimit * 2
        var clips: [Clip] = []
        var rows: [StatusItemMenuModel.Row] = []
        var offset = 0
        while rows.count < StatusItemMenuModel.defaultLimit {
            guard let page = try? database.recentClips(limit: pageSize, offset: offset), !page.isEmpty else { break }
            let pageRows = StatusItemMenuModel.rows(clips: page, limit: StatusItemMenuModel.defaultLimit - rows.count) {
                SensitiveContent.isSensitive(clip: $0)
            }
            rows.append(contentsOf: pageRows.map { StatusItemMenuModel.Row(clipIndex: $0.clipIndex + offset, title: $0.title) })
            clips.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }
        guard !rows.isEmpty else { return }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Recent Clips", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for row in rows {
            let item = NSMenuItem(title: row.title, action: #selector(pasteRecentClip(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = clips[row.clipIndex]
            item.setAccessibilityLabel("Paste \(row.title)")
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// Pastes a clip chosen from the status menu into the app that was frontmost.
    @objc func pasteRecentClip(_ sender: NSMenuItem) {
        guard let clip = sender.representedObject as? Clip else { return }
        panelController.onPaste?(clip, AppSettings.shared.pastePlainTextByDefault)
    }

    @objc func togglePause() {
        monitor.isPaused.toggle()
        updateStatusIcon()
    }
}
