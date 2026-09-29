import Foundation

/// Why an iCloud file operation was refused or failed.
enum ICloudSyncError: Error, Equatable, LocalizedError {
    /// The item never reached `ubiquitousItemDownloadingStatus == .current`
    /// within the wait, so writing could overwrite a newer, not-yet-downloaded copy.
    case downloadTimedOut(String)
    case coordinationFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadTimedOut(let name):
            return "iCloud has not finished downloading \(name). Nothing was written; try again when it has."
        case .coordinationFailed(let message): return "iCloud file coordination failed: \(message)"
        }
    }
}

/// The three questions the download wait asks the system, injectable for tests
/// (a real ubiquity container cannot be conjured in a unit test).
///
/// `@unchecked Sendable`: a probe is handed to a single sync task whose calls into it
/// are strictly sequential; the system probe is stateless, and test probes keep their
/// own mutable script that is only touched by that one task.
struct UbiquityProbe: @unchecked Sendable {
    var isUbiquitous: (URL) -> Bool
    var downloadStatus: (URL) -> URLUbiquitousItemDownloadingStatus?
    var startDownload: (URL) throws -> Void

    /// Computed so the closures are built per use rather than stored in shared state.
    static var system: UbiquityProbe {
        UbiquityProbe(
            isUbiquitous: { (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false },
            downloadStatus: {
                (try? $0.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
            },
            startDownload: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
        )
    }
}

/// Coordinated I/O and download handling shared by the sync service.
enum ICloudFileAccess {

    /// Block until `url` is fully downloaded and current (DAT-04), asking iCloud
    /// to start the download first. Returns immediately for an item that is not
    /// in iCloud or does not exist remotely at all; throws `downloadTimedOut`
    /// otherwise, so the caller never writes over an undownloaded copy.
    static func waitUntilCurrent(
        _ url: URL, probe: UbiquityProbe = .system,
        timeout: TimeInterval = 60, pollInterval: TimeInterval = 0.25
    ) async throws {
        let fileManager = FileManager.default
        // Pre-Sonoma placeholders: ".name.icloud" stands in for a missing file.
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        let exists = fileManager.fileExists(atPath: url.path)
        let hasPlaceholder = fileManager.fileExists(atPath: placeholder.path)
        guard hasPlaceholder || (exists && probe.isUbiquitous(url)) else { return }
        if exists, probe.downloadStatus(url) == .current { return }

        try? probe.startDownload(url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path), probe.downloadStatus(url) == .current { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ICloudSyncError.downloadTimedOut(url.lastPathComponent)
    }

    /// Read `url` under `NSFileCoordinator`; `body` runs while the coordinator
    /// holds the item, so other processes cannot change it mid-read.
    static func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinate { coordinator, error, accessor in
            coordinator.coordinate(readingItemAt: url, options: [], error: error, byAccessor: accessor)
        } body: { try body(url) }
    }

    /// Write/replace `url` under `NSFileCoordinator` with `.forReplacing`.
    static func coordinatedWrite<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = .forReplacing,
                                    _ body: (URL) throws -> T) throws -> T {
        try coordinate { coordinator, error, accessor in
            coordinator.coordinate(writingItemAt: url, options: options, error: error, byAccessor: accessor)
        } body: { try body(url) }
    }

    /// Move `source` to `destination` under coordination (used to set a bad
    /// archive aside without racing iCloud).
    static func coordinatedMove(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { thrown = error }
        }
        if let error = coordinationError ?? thrown as NSError? { throw error }
    }

    private static func coordinate<T>(
        _ run: (NSFileCoordinator, NSErrorPointer, (URL) -> Void) -> Void,
        body: () throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        // The accessor runs synchronously inside `run`, so `body` never outlives
        // this call; withoutActuallyEscaping lets the nested closure capture it.
        withoutActuallyEscaping(body) { escapableBody in
            run(coordinator, &coordinationError) { _ in
                outcome = Result { try escapableBody() }
            }
        }
        if let coordinationError { throw ICloudSyncError.coordinationFailed(coordinationError.localizedDescription) }
        guard let outcome else { throw ICloudSyncError.coordinationFailed("accessor never ran") }
        return try outcome.get()
    }

    // MARK: - Quarantine

    enum QuarantineOutcome: Equatable {
        /// Renamed in place next to the original.
        case movedAside(URL)
        /// The rename failed; the remote item is untouched and a copy was saved locally.
        case copiedLocally(URL)
        /// Neither worked; the remote item is untouched.
        case failed
    }

    /// Set an unusable remote archive aside so a good one can replace it. NEVER
    /// deletes the remote item (DAT-03): if the move fails it is copied into
    /// `localFallback` instead, and the caller must stop syncing (the remote is
    /// still there, still bad, so writing on top of it would destroy the only copy).
    static func quarantine(
        _ url: URL, localFallback: URL, now: Date = Date(),
        move: (URL, URL) throws -> Void = ICloudFileAccess.coordinatedMove
    ) -> QuarantineOutcome {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let name = "\(url.lastPathComponent).unreadable-\(stamp)"
        let sibling = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try move(url, sibling)
            return .movedAside(sibling)
        } catch {
            ClippyLog.error("iCloud quarantine move failed: \(error)", category: ClippyLog.sync)
        }
        do {
            try FileManager.default.createDirectory(at: localFallback, withIntermediateDirectories: true)
            let local = localFallback.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: local)
            return .copiedLocally(local)
        } catch {
            ClippyLog.error("iCloud quarantine local copy failed: \(error)", category: ClippyLog.sync)
            return .failed
        }
    }
}
