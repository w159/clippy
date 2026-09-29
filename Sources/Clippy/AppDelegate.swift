import AppKit
import Combine
import Darwin
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var statusIconObservers: [AnyCancellable] = []
    let onboardingController = OnboardingWindowController()
    let scriptsMenu = NSMenu()
    let keystrokeService = KeystrokeService()

    // Sparkle needs a packaged .app whose Info.plist carries SUFeedURL; when
    // running unbundled (swift run, smoke tests) leave the updater unstarted
    // so it stays inert and the menu item validates to disabled.
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Computed so the recovery Retry path re-acquires the live database after
    // ClipDatabase.retryLoad() replaces the in-memory sentinel with the real
    // on-disk database. The lazy vars below capture `database` on first access,
    // which in the Retry path happens AFTER the successful reopen.
    var database: ClipDatabase { ClipDatabase.shared }
    lazy var store = ClipStore(database: database, monitor: monitor)
    lazy var monitor = ClipboardMonitor(database: database)
    /// Picks up writes made by the MCP server process, which GRDB observation
    /// cannot see on its own.
    lazy var externalChangeWatcher = ExternalChangeWatcher(database: database)
    lazy var pasteService = PasteService(monitor: monitor)
    /// Hourly retention rules (FEAT-10), started at launch and stopped on quit.
    lazy var retentionService = RetentionService(database: database)
    /// Local event monitor feeding AppLock idle tracking.
    var activityMonitor: Any?
    lazy var panelController = PanelController(store: store)
    let editorController = EditorWindowController()

    // Strong reference required: a DispatchSourceMemoryPressure is suspended
    // and released if the owner goes away, silently disabling the safeguard.
    var memoryPressureSource: DispatchSourceMemoryPressure?

    /// `clippy://` URLs (and only those the URL scheme handler accepts) arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "clippy" { URLSchemeHandler.handle(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening the pool and applying migrations can wait on disk or SQLite;
        // do it before wiring DB consumers, but never on the UI thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<ClipDatabase, Error>
            do {
                let database = try ClipDatabase.loadShared()
                if let error = ClipDatabase.loadError { throw error }
                result = .success(database)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    self.continueLaunch()
                case .failure:
                    // Show the recovery path only after the background open
                    // recorded its failure, without blocking initial launch.
                    self.presentDatabaseRecoveryAlert()
                }
            }
        }
    }

    /// The full post-database launch sequence. Runs from the normal launch path
    /// and again from the recovery Retry path after a successful database reopen,
    /// so the recovered app gets the same setup as a clean launch.
    func continueLaunch() {
        setupStatusItem()
        setupMainMenu()
        monitor.start()

        // Log launch with version so post-mortem analysis can correlate log
        // lines to the exact binary that was running when a problem occurred.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        ClippyLog.info("Clippy launched — version \(version) (\(build))", category: ClippyLog.lifecycle)

        // Uncaught-exception handler: write name/reason/stack to the log file
        // synchronously before the process dies so the crash is always on disk,
        // not only in the os_log ring buffer which may roll over before diagnosis.
        NSSetUncaughtExceptionHandler { exception in
            let msg = "UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "(no reason)") | \(exception.callStackSymbols.prefix(20).joined(separator: " | "))"
            ClippyLog.syncWrite(msg, level: "FATAL")
        }

        installMemoryPressureSource()

        // Crash between media write and row insert leaves orphan files;
        // sweep them off the main thread at launch.
        DispatchQueue.global(qos: .utility).async {
            let referenced = (try? ClipDatabase.shared.referencedMediaFilenames()) ?? []
            ClipDatabase.shared.media.sweepOrphans(referencedFilenames: referenced)
        }

        // Kick off an iCloud Drive sync if the user has enabled it (safe no-op
        // otherwise; never touches CloudKit, so it cannot crash on launch).
        // Hop to MainActor because ICloudSyncService is @MainActor-isolated;
        // startIfEnabled() is a sync entry point that itself spawns the sync Task.
        Task { @MainActor in ICloudSyncService.shared.startIfEnabled() }

        // Start the MCP server if the user has enabled it, and wire up
        // live reactions to settings changes.
        McpServerController.shared.syncWithSettings()

        // ...and watch for what that server writes. GRDB observation is blind to
        // other processes, so without this a clip added over MCP stays invisible
        // until the next in-app write.
        externalChangeWatcher.start()

        configureHotKeys()
        wireLaunchServices()
        wireFeatureServices()

        wirePanelCallbacks()

        // Editor windows must not open behind the always-on-top panel (PNL-07).
        editorController.onWillOpen = { [weak self] in self?.panelController.hide() }
        // Reopen editors for unsaved text left by a previous quit or crash (EDT-01).
        // (after the first run-loop turn: reads draft files and the DB)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorController.recoverDrafts(store: self.store)
        }

        runDebugLaunchFlags()
        showOnboardingIfNeeded()
    }
}
