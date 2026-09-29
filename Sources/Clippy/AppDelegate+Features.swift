import AppKit
import SwiftUI

/// Launch/terminate wiring for the paste stack, snippets, URL scheme, intents and Spotlight.
@MainActor
private enum FeatureObservers {
    static var tokens: [NSObjectProtocol] = []
    static var distributed: [NSObjectProtocol] = []
    static var snippetSyncGeneration = 0
}

extension AppDelegate {
    /// Wires the feature services that need the live database, paste service and panel.
    func wireFeatureServices() {
        PasteStackController.launch(database: database, pasteService: pasteService)
        wireURLSchemeActions()
        wireSnippetExpander()
        DispatchQueue.global(qos: .utility).async { ClipSpotlightIndexer.donateRecent() }
    }

    /// Stops the feature services on quit.
    func terminateFeatureServices() {
        PasteStackController.terminate()
        SnippetExpander.shared.stop()
        QuickLookController.shared.close()
        FeatureObservers.tokens.forEach(NotificationCenter.default.removeObserver)
        FeatureObservers.distributed.forEach(DistributedNotificationCenter.default().removeObserver)
        FeatureObservers.tokens = []
        FeatureObservers.distributed = []
    }

    // MARK: - URL scheme and intents

    private func wireURLSchemeActions() {
        var actions = URLSchemeHandler.Actions()
        actions.showPanel = { [weak self] in self?.openPanel() }
        actions.showPanelSearching = { [weak self] _ in self?.openPanel() }
        actions.revealClip = { [weak self] _ in self?.openPanel() }
        actions.pasteLatest = { [weak self] in self?.pasteRecent(offset: 0, asPlainText: AppSettings.shared.pastePlainTextByDefault) }
        actions.showSettings = { [weak self] in self?.openSettings() }
        actions.showPalette = { [weak self] in self?.openPanel() }
        URLSchemeHandler.actions = actions
        let service = pasteService
        // Intents run off the main actor; PasteService is main-actor bound.
        IntentHooks.paste = { clip in
            DispatchQueue.main.async { service.paste(clip, asPlainText: AppSettings.shared.pastePlainTextByDefault) }
            return true
        }
    }

    // MARK: - Snippet expander

    private func wireSnippetExpander() {
        let database = self.database
        SnippetExpander.shared.clipboardProvider = {
            guard let clip = try? database.recentClips(limit: 1).first, clip.contentKind == .text,
                  !SensitiveContent.isSensitive(clip: clip) else { return "" }
            return clip.contentText
        }
        SnippetExpander.shared.fillProvider = { snippet, labels, done in
            SnippetFillPresenter.present(name: snippet.title, labels: labels, done: done)
        }
        // AX trust checks can cross into system services; syncSnippetExpander
        // runs that probe off-main so snippet setup never delays launch.
        syncSnippetExpander()
        let center = NotificationCenter.default
        let resync: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.syncSnippetExpander() } }
        FeatureObservers.tokens = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: resync),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: resync)
        ]
        // Accessibility trust changes are broadcast system-wide.
        FeatureObservers.distributed = [
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main, using: resync)
        ]
    }

    /// Starts or stops the expander to match the enable setting and Accessibility trust.
    func syncSnippetExpander() {
        FeatureObservers.snippetSyncGeneration &+= 1
        let generation = FeatureObservers.snippetSyncGeneration
        let enabled = SnippetSettings.isExpansionEnabled
        Task.detached(priority: .utility) {
            let trusted = CaretLocator.isTrusted
            await MainActor.run {
                guard generation == FeatureObservers.snippetSyncGeneration else { return }
                let expander = SnippetExpander.shared
                let wanted = enabled && trusted
                if wanted && !expander.isRunning { expander.start() }
                else if !wanted && expander.isRunning { expander.stop() }
            }
        }
    }

    // MARK: - Settings shortcuts

    /// Help > Command Line Tool...: opens Settings on the Automation pane.
    @objc func openAutomationSettings() {
        setenv("CLIPPY_SETTINGS_SECTION", SettingsPaneID.automation.rawValue, 1)
        settingsWindow?.close()
        settingsWindow = nil
        openSettings()
    }
}

/// Presents `SnippetFillView` in a small floating panel; `done` fires exactly once.
@MainActor
enum SnippetFillPresenter {
    private static var window: NSWindow?

    /// One presentation: delivers `done` exactly once, whichever of the form's own
    /// buttons or the window's close box ends it first.
    @MainActor
    private final class Session {
        private var finished = false
        var closeObserver: NSObjectProtocol?
        private let done: ([String: String]?) -> Void

        init(done: @escaping ([String: String]?) -> Void) { self.done = done }

        func finish(_ values: [String: String]?) {
            guard !finished else { return }
            finished = true
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            SnippetFillPresenter.window?.close()
            SnippetFillPresenter.window = nil
            done(values)
        }
    }

    static func present(name: String, labels: [String], done: @escaping ([String: String]?) -> Void) {
        let session = Session(done: done)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Snippet"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SnippetFillView(snippetName: name, labels: labels, onFinish: { session.finish($0) }))
        session.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                                       queue: .main) { _ in MainActor.assumeIsolated { session.finish(nil) } }
        window = panel
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}
