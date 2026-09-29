import AppKit
import UniformTypeIdentifiers

// MARK: - Preference

/// One installed app that can open plain text, for the external-editor picker.
struct ExternalEditorChoice: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

/// Which app "Edit in External Editor" opens. Persisted in UserDefaults under
/// an `editor.` key so the Settings redesign can bind a picker to it without
/// touching AppSettings.
enum ExternalEditorPreference {
    /// UserDefaults key holding the chosen app's bundle identifier.
    static let defaultsKey = "editor.externalAppBundleID"

    /// Sublime Text bundle ids, newest first. Used as the fallback preference
    /// when the user has not picked an app, preserving the old default.
    static let sublimeBundleIDs = ["com.sublimetext.4", "com.sublimetext.3"]

    /// The chosen bundle id, or nil when the user has not picked one.
    static func bundleID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Persists the choice. Pass nil to fall back to the automatic choice.
    static func setBundleID(_ id: String?, defaults: UserDefaults = .standard) {
        if let id, !id.isEmpty {
            defaults.set(id, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// Installed apps that declare they can open `public.plain-text`, sorted by
    /// name. The user's persisted choice is always included when installed so
    /// the picker can show it even if LaunchServices does not list it.
    @MainActor
    static func installedEditors(defaults: UserDefaults = .standard) -> [ExternalEditorChoice] {
        let workspace = NSWorkspace.shared
        var urls = workspace.urlsForApplications(toOpen: UTType.plainText)
        if let chosen = bundleID(defaults: defaults),
           let url = workspace.urlForApplication(withBundleIdentifier: chosen),
           !urls.contains(url) {
            urls.append(url)
        }
        var seen = Set<String>()
        var choices: [ExternalEditorChoice] = []
        for url in urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            choices.append(ExternalEditorChoice(bundleID: id, name: name, url: url))
        }
        return choices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app that will open the temp file: the persisted choice when it is
    /// installed, else Sublime Text when installed, else nil (system default).
    @MainActor
    static func resolvedAppURL(defaults: UserDefaults = .standard) -> URL? {
        let workspace = NSWorkspace.shared
        if let chosen = bundleID(defaults: defaults),
           let url = workspace.urlForApplication(withBundleIdentifier: chosen) {
            return url
        }
        for id in sublimeBundleIDs {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }
}

// MARK: - Seams

/// Change reported by a file watch.
enum ExternalEditorWatchEvent: Equatable {
    /// Contents were written in place.
    case modified
    /// The file was renamed over or deleted (atomic save); the watch is dead
    /// and must be re-armed against the new inode.
    case replaced
}

/// A live file watch. Cancelling releases its file descriptor and presenter.
@MainActor
protocol ExternalEditorWatch: AnyObject {
    func cancel()
}

/// File-system operations the session needs, injectable so debounce, guard,
/// and re-arm logic are testable without touching the disk or the clock.
@MainActor
protocol ExternalEditorFileSystem: AnyObject {
    /// The file's text, or nil when it is missing or unreadable.
    func read(_ url: URL) -> String?
    func write(_ text: String, to url: URL) throws
    func remove(_ url: URL)
    /// Starts watching `url`; nil when it cannot be opened (for example the
    /// instant between an atomic save's delete and rename). Events arrive on
    /// the main actor.
    func watch(_ url: URL, handler: @escaping @MainActor (ExternalEditorWatchEvent) -> Void) -> ExternalEditorWatch?
}

/// Cancellable timer token.
protocol ExternalEditorTimer: AnyObject {
    func cancel()
}

/// Delayed main-actor work, injectable so tests advance time deterministically.
@MainActor
protocol ExternalEditorScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ExternalEditorTimer
}

// MARK: - Session

/// One text clip round-tripping through an external editor. Owns the temp
/// file, the watcher, and the sync state; `close()` releases all of them.
///
/// Rules (EDT-03/04):
/// - file events are debounced (default 250 ms) into one read;
/// - an empty read is ignored while the previous text was non-empty, because a
///   non-atomic save truncates the file before writing it;
/// - `lastKnownText` advances only after `persist` reports success, so a failed
///   write is retried by the next event or the retry timer;
/// - after an atomic save (`.replaced`) the watch is re-armed with backoff.
@MainActor
final class ExternalEditorSession {
    let clipID: Int64
    let url: URL
    /// Text last written to (or confirmed synced with) the clip.
    private(set) var lastKnownText: String
    /// False after a re-arm exhausted its retries: on-disk edits are no longer seen.
    private(set) var isWatching = false
    private(set) var isClosed = false
    /// Consecutive failed persists since the last success.
    private(set) var persistFailures = 0

    /// Invoked after a successful sync from disk, with the synced text.
    var onSynced: ((String) -> Void)?

    static let defaultDebounce: TimeInterval = 0.25
    static let maxRearmAttempts = 8
    static let maxPersistRetries = 5

    private let fileSystem: ExternalEditorFileSystem
    private let scheduler: ExternalEditorScheduler
    private let debounce: TimeInterval
    private let persist: (String) -> Bool
    private var watch: ExternalEditorWatch?
    private var debounceTimer: ExternalEditorTimer?
    private var rearmTimer: ExternalEditorTimer?
    private var retryTimer: ExternalEditorTimer?

    /// - Parameters:
    ///   - persist: writes the text into the clip; returns true when it landed.
    init(
        clipID: Int64,
        url: URL,
        initialText: String,
        fileSystem: ExternalEditorFileSystem,
        scheduler: ExternalEditorScheduler,
        debounce: TimeInterval = ExternalEditorSession.defaultDebounce,
        persist: @escaping (String) -> Bool
    ) {
        self.clipID = clipID
        self.url = url
        self.lastKnownText = initialText
        self.fileSystem = fileSystem
        self.scheduler = scheduler
        self.debounce = debounce
        self.persist = persist
    }

    /// Writes the initial text to the temp file and arms the watcher.
    func start() throws {
        try fileSystem.write(lastKnownText, to: url)
        armWatch()
    }

    /// Tears the session down: cancels timers and the watch (closing its file
    /// descriptor) and removes the temp file. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        debounceTimer?.cancel(); debounceTimer = nil
        rearmTimer?.cancel(); rearmTimer = nil
        retryTimer?.cancel(); retryTimer = nil
        watch?.cancel(); watch = nil
        isWatching = false
        fileSystem.remove(url)
    }

    /// Two-way sync: pushes an in-app edit into the temp file so the external
    /// editor reloads it. Any pending on-disk change is synced first so it is
    /// not overwritten unseen. Returns false when the write failed.
    @discardableResult
    func pushFromApp(_ text: String) -> Bool {
        guard !isClosed else { return false }
        if debounceTimer != nil { flush() }
        guard text != lastKnownText else { return true }
        do {
            try fileSystem.write(text, to: url)
        } catch {
            ClippyLog.error("external edit: cannot update temp file: \(error)", category: ClippyLog.storage)
            return false
        }
        // The write is our own; recording it first makes the resulting watch
        // event read back the same text and do nothing.
        lastKnownText = text
        return true
    }

    /// A file event arrived (from the watcher or a file presenter).
    func fileDidChange(_ event: ExternalEditorWatchEvent = .modified) {
        guard !isClosed else { return }
        if event == .replaced {
            watch?.cancel(); watch = nil
            isWatching = false
            rearm(attempt: 0)
        }
        scheduleSync()
    }

    /// Runs any pending debounced sync immediately.
    func flush() {
        guard !isClosed else { return }
        debounceTimer?.cancel(); debounceTimer = nil
        syncFromDisk()
    }

    // MARK: Sync

    private func scheduleSync() {
        debounceTimer?.cancel()
        debounceTimer = scheduler.schedule(after: debounce) { [weak self] in
            guard let self else { return }
            self.debounceTimer = nil
            self.syncFromDisk()
        }
    }

    private func syncFromDisk() {
        guard !isClosed, let text = fileSystem.read(url) else { return }
        if text.isEmpty, !lastKnownText.isEmpty {
            ClippyLog.info("external edit: clip \(clipID) ignored empty read", category: ClippyLog.storage)
            return
        }
        guard text != lastKnownText else { return }
        if persist(text) {
            lastKnownText = text
            persistFailures = 0
            ClippyLog.info("external edit: clip \(clipID) synced (\(text.count) chars)", category: ClippyLog.storage)
            onSynced?(text)
        } else {
            persistFailures += 1
            ClippyLog.error("external edit: clip \(clipID) save failed", category: ClippyLog.storage)
            guard persistFailures <= Self.maxPersistRetries, retryTimer == nil else { return }
            retryTimer = scheduler.schedule(after: 1) { [weak self] in
                guard let self else { return }
                self.retryTimer = nil
                self.syncFromDisk()
            }
        }
    }

    // MARK: Watching

    private func armWatch() {
        watch?.cancel()
        watch = fileSystem.watch(url) { [weak self] event in
            self?.fileDidChange(event)
        }
        isWatching = watch != nil
    }

    /// Re-opens the watch after an atomic save, backing off while the new file
    /// is not there yet. A successful re-arm also syncs, since the change that
    /// triggered it may have landed before the new watch existed.
    private func rearm(attempt: Int) {
        rearmTimer?.cancel(); rearmTimer = nil
        guard !isClosed else { return }
        armWatch()
        if isWatching {
            scheduleSync()
            return
        }
        guard attempt < Self.maxRearmAttempts else {
            ClippyLog.error("external edit: clip \(clipID) watcher could not re-arm", category: ClippyLog.storage)
            return
        }
        let delay = min(0.05 * pow(2, Double(attempt)), 2)
        rearmTimer = scheduler.schedule(after: delay) { [weak self] in
            self?.rearm(attempt: attempt + 1)
        }
    }
}

// MARK: - System implementations

/// Real file system: a DispatchSource on the file plus an NSFilePresenter for
/// coordinated writers. Both report through one handler.
@MainActor
final class SystemExternalEditorFileSystem: ExternalEditorFileSystem {
    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func watch(_ url: URL, handler: @escaping @MainActor (ExternalEditorWatchEvent) -> Void) -> ExternalEditorWatch? {
        SystemFileWatch(url: url, handler: handler)
    }
}

/// Dispatch source + file presenter pair. The descriptor closes in the source's
/// cancel handler; the presenter is removed in `cancel()`.
@MainActor
private final class SystemFileWatch: NSObject, ExternalEditorWatch, NSFilePresenter {
    let presentedItemURL: URL?
    nonisolated let presentedItemOperationQueue: OperationQueue = .main
    private var source: DispatchSourceFileSystemObject?
    private let handler: @MainActor (ExternalEditorWatchEvent) -> Void
    private var cancelled = false

    init?(url: URL, handler: @escaping @MainActor (ExternalEditorWatchEvent) -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.presentedItemURL = url
        self.handler = handler
        super.init()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let data = source.data
            MainActor.assumeIsolated {
                self.emit(data.contains(.rename) || data.contains(.delete) ? .replaced : .modified)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
        NSFileCoordinator.addFilePresenter(self)
    }

    private func emit(_ event: ExternalEditorWatchEvent) {
        guard !cancelled else { return }
        handler(event)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        NSFileCoordinator.removeFilePresenter(self)
        source?.cancel()
        source = nil
    }

    nonisolated func presentedItemDidChange() {
        MainActor.assumeIsolated { self.emit(.modified) }
    }
}

/// Real scheduler on the main queue.
@MainActor
final class MainQueueExternalEditorScheduler: ExternalEditorScheduler {
    private final class Timer: ExternalEditorTimer {
        var item: DispatchWorkItem?
        func cancel() { item?.cancel(); item = nil }
    }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ExternalEditorTimer {
        let timer = Timer()
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        timer.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return timer
    }
}

// MARK: - Service

/// Round-trips a text clip through an external editor chosen in
/// `ExternalEditorPreference` (Sublime Text, else the system default for plain
/// text). Each clip has at most one `ExternalEditorSession`; the editor window
/// closes it via `closeSession(clipID:)` and app quit via `closeAll()`, which
/// remove the temp files.
@MainActor
final class ExternalEditorService {
    static let shared = ExternalEditorService()

    private var sessions: [Int64: ExternalEditorSession] = [:]
    private let fileSystem: ExternalEditorFileSystem
    private let scheduler: ExternalEditorScheduler
    private let defaults: UserDefaults

    init(
        fileSystem: ExternalEditorFileSystem? = nil,
        scheduler: ExternalEditorScheduler? = nil,
        defaults: UserDefaults = .standard
    ) {
        // Defaults are built here, inside the main-actor init body: default
        // argument expressions are evaluated in a nonisolated context.
        self.fileSystem = fileSystem ?? SystemExternalEditorFileSystem()
        self.scheduler = scheduler ?? MainQueueExternalEditorScheduler()
        self.defaults = defaults
    }

    /// Menu label for the external-edit action, naming the app that will open.
    var menuTitle: String {
        if let url = ExternalEditorPreference.resolvedAppURL(defaults: defaults) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return "Edit in \(name)..."
        }
        return "Edit in External Editor..."
    }

    /// The live session for a clip, if any.
    func session(for clipID: Int64) -> ExternalEditorSession? { sessions[clipID] }

    /// Opens `clip` in the external editor and starts syncing both ways.
    /// Re-invoking for a clip that already has a session re-opens the same
    /// file, so the editor focuses the existing document.
    func edit(clip: Clip, store: ClipStore) {
        guard clip.contentKind == .text, let clipID = clip.id else { return }

        if let existing = sessions[clipID] {
            openInEditor(existing.url)
            return
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyExternalEdit", isDirectory: true)
        // Human-readable filename so the editor tab is tellable apart; the id
        // prefix keeps names unique when titles collide.
        let safeTitle = clip.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .prefix(40)
        let url = dir.appendingPathComponent("clip-\(clipID)-\(safeTitle).txt")

        let session = ExternalEditorSession(
            clipID: clipID,
            url: url,
            initialText: clip.contentText,
            fileSystem: fileSystem,
            scheduler: scheduler,
            persist: { [weak store] text in
                store?.updateText(of: clip, to: text) ?? false
            }
        )
        do {
            try session.start()
        } catch {
            ClippyLog.error("external edit: cannot write temp file: \(error)", category: ClippyLog.storage)
            session.close()
            return
        }
        sessions[clipID] = session
        openInEditor(url)
    }

    /// Pushes text saved in the in-app editor to the temp file. No-op when the
    /// clip has no session.
    func pushFromApp(text: String, clipID: Int64) {
        sessions[clipID]?.pushFromApp(text)
    }

    /// Flushes and closes the clip's session, deleting its temp file.
    func closeSession(clipID: Int64) {
        guard let session = sessions.removeValue(forKey: clipID) else { return }
        session.flush()
        session.close()
    }

    /// Closes every session (app quit).
    func closeAll() {
        for id in Array(sessions.keys) { closeSession(clipID: id) }
    }

    private func openInEditor(_ url: URL) {
        if let appURL = ExternalEditorPreference.resolvedAppURL(defaults: defaults) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
