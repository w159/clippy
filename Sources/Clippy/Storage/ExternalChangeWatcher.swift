import Foundation
import GRDB

/// Makes writes from outside the app show up in the panel.
///
/// The MCP server is a separate process holding its own SQLite connection to the
/// same file. GRDB's `ValueObservation` is explicit that it does not detect
/// changes made through external connections, so a clip added over MCP used to
/// sit in the database invisibly until the next in-app write or an app restart.
///
/// The signal is SQLite's `data_version` pragma, which is designed for exactly
/// this: it is bumped by commits from *other* connections and left unchanged for
/// commits on the connection that reads it. It is read on the pool's WRITER
/// connection (readers never commit), so a change here means somebody else
/// wrote, with no false positives from our own captures.
///
/// The poll runs on a background queue (DAT-10) because reading the pragma on
/// the writer connection can wait behind an in-flight write; the file-store
/// reloaders stay on the main thread since they publish UI state. The version is
/// advanced only after the GRDB refresh succeeded, so a failed notify is retried
/// on the next tick instead of being lost.
///
/// On a change we ask GRDB to republish via `notifyChanges(in:)`, which is the
/// documented escape hatch for undetected changes.
/// Scripts and AI actions live in JSON files rather than the database, and have
/// the same problem in a worse form: the app holds them in memory, so an MCP
/// write is not merely unseen, it is overwritten by the next in-app save. They
/// are polled on the same tick by modification date.
@MainActor
final class ExternalChangeWatcher {
    private let interval: TimeInterval
    private let fileStoreReloaders: [@MainActor () -> Bool]
    private let poller: DatabasePoller
    private var timer: Timer?
    private let pollQueue = DispatchQueue(label: "com.clippy.ExternalChangeWatcher", qos: .utility)

    /// 2s: fast enough that "Claude, file these clips" feels live, slow enough
    /// that the pragma read is free. The read is a single integer from the page
    /// cache, not a query.
    ///
    /// `fileStoreReloaders` defaults to the two live singletons; tests pass their
    /// own (or none) to stay off shared state.
    init(database: ClipDatabase,
         interval: TimeInterval = 2.0,
         fileStoreReloaders: [@MainActor () -> Bool] = [
            { ScriptStore.shared.reloadIfModifiedExternally() },
            { AIActionStore.shared.reloadIfModifiedExternally() },
         ],
         notifyChanges: (() throws -> Void)? = nil) {
        self.interval = interval
        self.fileStoreReloaders = fileStoreReloaders
        self.poller = DatabasePoller(database: database,
                                     notify: notifyChanges ?? { try database.notifyExternalChanges() })
    }

    func start() {
        stop()
        poller.resetBaseline()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        // .common so the poll keeps running while a menu or drag tracks the run loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Timer entry (main thread): reload file stores here, poll the database off-main.
    private func timerFired() {
        for reload in fileStoreReloaders { _ = reload() }
        pollQueue.async { [poller] in
            _ = poller.refreshIfChanged()
        }
    }

    /// Internal so tests can drive it without waiting on a run loop.
    /// Returns true when anything was refreshed.
    @discardableResult
    func tick() -> Bool {
        var refreshed = false
        // Reloaders first: they are independent of the database and must run even
        // if the pragma read fails.
        for reload in fileStoreReloaders where reload() {
            refreshed = true
        }
        if poller.refreshIfChanged() { refreshed = true }
        return refreshed
    }

    isolated deinit { timer?.invalidate() }
}

/// The database half of the watcher: reads `data_version` and republishes GRDB
/// observations. It runs on a background queue (timer ticks) and on the caller's
/// thread (`tick()`), so every poll is serialized by `lock`.
///
/// `@unchecked Sendable`: `lastDataVersion` is only touched under `lock`, and
/// `notify` is a caller-supplied (test-injectable, non-Sendable) closure that is
/// only ever invoked while `lock` is held, so it never runs concurrently with itself.
private final class DatabasePoller: @unchecked Sendable {
    private let database: ClipDatabase
    private let notify: () throws -> Void
    private let lock = NSLock()
    private var lastDataVersion: Int64?

    init(database: ClipDatabase, notify: @escaping () throws -> Void) {
        self.database = database
        self.notify = notify
    }

    func resetBaseline() {
        lock.withLock { lastDataVersion = try? database.dataVersion() }
    }

    func refreshIfChanged() -> Bool {
        lock.withLock {
            guard let current = try? database.dataVersion() else { return false }
            guard let previous = lastDataVersion else {
                lastDataVersion = current
                return false
            }
            guard previous != current else { return false }
            do {
                try notify()
                // Only now is the change "seen"; on failure the old version stays so
                // the next tick retries.
                lastDataVersion = current
                ClippyLog.info("External database change detected (data_version \(previous) -> \(current)); refreshed observations",
                               category: ClippyLog.storage)
                return true
            } catch {
                ClippyLog.error("Failed to refresh after external database change: \(error)",
                                category: ClippyLog.storage)
                return false
            }
        }
    }
}
