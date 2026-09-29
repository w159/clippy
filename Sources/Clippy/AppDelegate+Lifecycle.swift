import AppKit
import Darwin
import SwiftUI

extension AppDelegate {
    // MARK: - Launch helpers

    /// Wires the launch-time services owned by other areas: OCR indexing, own-write
    /// suppression for keyboard copies, the OCR warm-up probe, retention and app lock.
    func wireLaunchServices() {
        // OCR indexing is a background catch-up job; starting it off-main keeps
        // its DB reads and Vision warm-up from delaying panel usability.
        DispatchQueue.global(qos: .utility).async { OCRIndexer.startShared() }
        let monitor = self.monitor
        ClipCopyBridge.wrapOwnWrite = { body in monitor.performOwnWrite(body) }
        let imageProbe = CachedImageClipProbe(database: ClipDatabase.shared)
        imageProbe.refresh()
        OCRWarmupPolicy.shared.hasImageClips = { imageProbe.current() }
        Task { @MainActor in
            self.retentionService.start()
            AppLock.shared.start()
        }
        // Any key or click inside Clippy counts as activity for the idle lock.
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            AppLock.shared.noteActivity()
            return event
        }
    }

    /// Shows the first-run walkthrough unless a debug flag drives the launch.
    func showOnboardingIfNeeded() {
        let flags = ["--show-panel", "--screenshot", "--screenshot-settings", "--icloud-selftest"]
        guard !CommandLine.arguments.contains(where: flags.contains) else { return }
        Task { @MainActor in self.onboardingController.showIfNeeded() }
    }

    /// Frees caches when the OS reports memory pressure.
    func installMemoryPressureSource() {
        // Memory-pressure source: the OS notifies us before it starts killing
        // processes. On warning we free the thumbnail cache (the primary 4 GB
        // cause); on critical we also trim the in-memory clip array so SwiftUI
        // can release its retained Clip values and backing storage.
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = pressureSource.data
            let rss = Self.residentMemoryMB()
            if event.contains(.critical) {
                ClippyLog.error("Memory pressure CRITICAL — RSS ~\(rss) MB; purging cache + trimming clips",
                                category: ClippyLog.lifecycle)
                ClipCardView.purgeThumbnailCache()
                self.store.trimResident()
            } else if event.contains(.warning) {
                ClippyLog.info("Memory pressure WARNING — RSS ~\(rss) MB; purging thumbnail cache",
                               category: ClippyLog.lifecycle)
                ClipCardView.purgeThumbnailCache()
            }
        }
        pressureSource.resume()
        memoryPressureSource = pressureSource
    }

    /// Debug launch flags used by UI smoke tests (--show-panel, --screenshot, ...).
    func runDebugLaunchFlags() {
        // Debug aids: open the panel right after launch, or render it to a
        // PNG and exit (used by UI smoke tests that cannot press the global
        // hotkey).
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panelController.show()
            }
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--screenshot"),
           CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.panelController.show()
                // Optional `--screenshot-query <text>` types into the search field first, so
                // filter chips, highlights and the no-results state can be rendered headlessly.
                if let queryIndex = CommandLine.arguments.firstIndex(of: "--screenshot-query"),
                   CommandLine.arguments.indices.contains(queryIndex + 1) {
                    self?.panelController.store.query = CommandLine.arguments[queryIndex + 1]
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.panelController.snapshotPanel(to: url)
                    NSApp.terminate(nil)
                }
            }
        }
        // Proves the iCloud sync path runs end to end (file write/read, archive
        // round-trip) without crashing, against a temp folder instead of the real
        // iCloud Drive. Used to validate that enabling sync can never crash.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--icloud-selftest"),
           CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            Task { @MainActor in
                let service = ICloudSyncService(rootOverride: dir)
                await service.sync(force: true)
                ClippyLog.info("ICLOUD_SELFTEST status=\(service.status)", category: ClippyLog.sync)
                let synced = dir.appendingPathComponent("Clippy/clippy-sync.toml")
                ClippyLog.info("ICLOUD_SELFTEST file_exists=\(FileManager.default.fileExists(atPath: synced.path))",
                               category: ClippyLog.sync)
                NSApp.terminate(nil)
            }
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--screenshot-settings"),
           CommandLine.arguments.indices.contains(flagIndex + 1)
        {
            let path = CommandLine.arguments[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    // Render the window's frame view (not just contentView) so the sidebar's
                    // AppKit-backed list/search field resolve the window's effective appearance
                    // and key/active state, matching what a user sees on screen.
                    self?.settingsWindow?.makeKeyAndOrderFront(nil)
                    // Prefer a real compositor capture (glass sidebar/search field do not render
                    // through cacheDisplay); fall back to the view snapshot below if it fails.
                    if let number = self?.settingsWindow?.windowNumber {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(number), path]
                        try? capture.run()
                        capture.waitUntilExit()
                        if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: path) {
                            NSApp.terminate(nil)
                            return
                        }
                    }
                    if let view = self?.settingsWindow?.contentView?.superview,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Database recovery

    /// Shows a modal alert when the on-disk database could not be opened,
    /// offering Show in Finder (opens Application Support/Clippy), Retry
    /// (re-attempts the open and continues launch if it succeeds), and Quit.
    /// Replaces the fatalError crash path reported in the UI/UX audit.
    func presentDatabaseRecoveryAlert() {
        let message = ClipDatabase.loadError.map { "\($0)" } ?? "Unknown database error."
        let alert = NSAlert()
        alert.messageText = "Clippy could not open its clipboard database."
        alert.informativeText = "\(message)\n\nThe database lives in Application Support/Clippy. " +
            "You can reveal it in Finder, retry after fixing the issue, or quit."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .critical
        NSApp.activate()
        let choice = alert.runModal()
        switch choice {
        case .alertFirstButtonReturn:
            // Reveal the Application Support/Clippy folder so the user can
            // inspect permissions / free disk space / remove a corrupt file.
            NSWorkspace.shared.activateFileViewerSelecting([ClipDatabase.shared.databaseURL])
            // After revealing, re-show the alert so the user can Retry or Quit
            // without the app silently continuing on the sentinel.
            presentDatabaseRecoveryAlert()
        case .alertSecondButtonReturn:
            if ClipDatabase.retryLoad() != nil {
                // Recovery succeeded: run the full launch sequence so the
                // reopened database is wired into the store, monitor, and panel
                // exactly as on a clean launch.
                continueLaunch()
            } else {
                // Still failing: loop back to the alert.
                presentDatabaseRecoveryAlert()
            }
        default:
            NSApp.terminate(nil)
        }
    }


    /// Quitting must not silently discard open editors (EDT-01). Dirty text
    /// editors are saved as drafts and reopened at the next launch; dirty image
    /// editors, which are not drafted, ask before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editorController.hasDirtyImageEditors {
            let alert = NSAlert()
            alert.messageText = "Quit with unsaved image edits?"
            alert.informativeText = "Image edits are not restored after quitting. Cancel to go back and save them."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            NSApp.activate()
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if editorController.hasDirtyTextEditors, !editorController.autosaveDrafts() {
            let alert = NSAlert()
            alert.messageText = "Clippy could not save your unsaved text edits."
            alert.informativeText = "Quitting now will discard them. Cancel to go back and save them."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .critical
            NSApp.activate()
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        editorController.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClippyLog.info("Clippy shutting down cleanly", category: ClippyLog.lifecycle)
        // Remove external-editor temp files (clip text) from disk.
        ExternalEditorService.shared.closeAll()
        terminateFeatureServices()
        externalChangeWatcher.stop()
        HotKeyCenter.shared.unregisterAll()
        AppLock.shared.stop()
        OCRIndexer.shared.stop()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        Task { @MainActor in self.retentionService.stop() }
        // Ensure the node MCP server process never outlives the app.
        McpServerController.shared.stop()
    }

    // MARK: - Memory helpers

    /// Read the process's current resident set size via mach_task_basic_info.
    /// Returns 0 if the call fails (non-fatal; used only for log context).
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / (1024 * 1024)
    }
}
