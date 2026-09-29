import AppKit

// MARK: - Window configuration

extension PanelController {
    /// Applies the user's panelFloatLevel preference to a panel instance.
    /// alwaysOnTop: .statusBar (25) + isFloatingPanel — the original behavior, floats
    ///   above every normal app window and full-screen chrome.
    /// aboveNormalWindows: .floating + isFloatingPanel — above normal windows, but
    ///   below status bar and menu extras.
    /// normalOrder: .normal + not floating — participates in standard z-order.
    func applyFloatLevel(to panel: PastePanel) {
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

    /// PNL-03: the smallest panel frame the layout supports. The content minimum
    /// (rail + one card + gutters, header + rows + footer) is converted to a frame
    /// size because a titled window's frame includes the hidden titlebar.
    func minimumFrameSize(for panel: PastePanel) -> NSSize {
        let content = PanelLayout.standardMinimumSize
        return panel.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    /// The configured panel size raised to the layout minimum (PNL-03).
    func clampedPanelSize(in panel: PastePanel) -> NSSize {
        let saved = CGSize(width: settings.panelWidth, height: settings.panelHeight)
        return PanelLayout.clampUp(saved, toMinimum: minimumFrameSize(for: panel))
    }

    /// PNL-07: while another Clippy window (Settings, editor) is key the panel drops
    /// to `.normal` so it cannot cover that window; it regains the configured level
    /// when it becomes key again.
    func observeOtherWindows() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            // queue: .main guarantees the main thread; only the window crosses the hop.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, let window = object as? NSWindow else { return }
                if window === panel {
                    self.applyFloatLevel(to: panel)
                } else if window.canBecomeMain {
                    panel.level = .normal
                    panel.isFloatingPanel = false
                }
            }
        }
    }

    /// Creates the panel window once: hidden-titlebar chrome with AppKit resize
    /// edges (PNL-02), movable (PNL-01), clear glass backdrop, accessibility identity.
    func ensurePanel() -> PastePanel {
        if let panel { return panel }
        let panel = PastePanel(
            contentRect: NSRect(x: 0, y: 0, width: settings.panelWidth, height: settings.panelHeight),
            styleMask: PastePanel.chromeStyleMask,
            backing: .buffered,
            defer: true
        )
        panel.applyChrome()
        // Level and float behavior are applied per-show so live changes to
        // panelFloatLevel take effect the next time the panel opens.
        applyFloatLevel(to: panel)
        panel.hidesOnDeactivate = false
        panel.minSize = minimumFrameSize(for: panel)
        // .canJoinAllSpaces: stays visible across space switches.
        // .fullScreenAuxiliary: renders over full-screen apps.
        // .managed (not .transient): the window manager keeps it in the current
        //   space instead of evicting it during Mission Control transitions.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        // PNL-12: without these the panel reports as AXSystemDialog with no title.
        panel.title = "Clippy"
        panel.setAccessibilityTitle("Clippy clipboard history")
        panel.setAccessibilityLabel("Clippy clipboard history")
        panel.setAccessibilityIdentifier("clippy.panel")
        panel.setAccessibilitySubrole(.floatingWindow)
        // Route Escape through hide() so the origin and remembered size are
        // preserved (cancelOperation used to orderOut(nil) and skip the save).
        panel.onCancel = { [weak self] in self?.hide() }
        self.panel = panel
        return panel
    }
}
