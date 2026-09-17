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
/// commits on the connection that reads it. Clippy uses a single `DatabaseQueue`
/// (one connection), so a change here means somebody else wrote, with no false
/// positives from our own captures.
///
/// On a change we ask GRDB to republish via `notifyChanges(in:)`, which is the
/// documented escape hatch for undetected changes.
/// Scripts and AI actions live in JSON files rather than the database, and have
/// the same problem in a worse form: the app holds them in memory, so an MCP
/// write is not merely unseen, it is overwritten by the next in-app save. They
/// are polled on the same tick by modification date.
final class ExternalChangeWatcher {
    private let database: ClipDatabase
    private let interval: TimeInterval
    private let fileStoreReloaders: [() -> Bool]
    private var timer: Timer?
    private var lastDataVersion: Int64?

    /// 2s: fast enough that "Claude, file these clips" feels live, slow enough
    /// that the pragma read is free. The read is a single integer from the page
    /// cache, not a query.
    ///
    /// `fileStoreReloaders` defaults to the two live singletons; tests pass their
    /// own (or none) to stay off shared state.
    init(database: ClipDatabase,
         interval: TimeInterval = 2.0,
         fileStoreReloaders: [() -> Bool] = [
            { ScriptStore.shared.reloadIfModifiedExternally() },
            { AIActionStore.shared.reloadIfModifiedExternally() },
         ]) {
        self.database = database
        self.interval = interval
        self.fileStoreReloaders = fileStoreReloaders
    }

    func start() {
        stop()
        lastDataVersion = try? database.dataVersion()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the poll keeps running while a menu or drag tracks the run loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        if refreshDatabaseIfChanged() { refreshed = true }
        return refreshed
    }

    private func refreshDatabaseIfChanged() -> Bool {
        guard let current = try? database.dataVersion() else { return false }
        defer { lastDataVersion = current }
        guard let previous = lastDataVersion, previous != current else { return false }
        do {
            try database.notifyExternalChanges()
            ClippyLog.info("External database change detected (data_version \(previous) -> \(current)); refreshed observations",
                           category: ClippyLog.storage)
            return true
        } catch {
            ClippyLog.error("Failed to refresh after external database change: \(error)",
                            category: ClippyLog.storage)
            return false
        }
    }

    deinit { timer?.invalidate() }
}
