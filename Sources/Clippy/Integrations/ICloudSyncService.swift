import Foundation

/// iCloud sync that actually works for a Developer-ID / Sparkle-distributed app.
///
/// CloudKit is intentionally NOT used: it requires App Store or development
/// provisioning that a directly-distributed (Developer ID) app cannot have, and
/// touching it without the entitlement crashes the process. Instead this writes
/// Clippy's archive package into the user's iCloud Drive folder. A non-sandboxed
/// app can read and write there with no entitlement, and iCloud uploads/downloads
/// it across the user's Macs.
///
/// Safety properties (DAT-03/04/05):
///   - every read and write of the remote archive is under `NSFileCoordinator`;
///   - nothing is written until the remote item is fully downloaded
///     (`ubiquitousItemDownloadingStatus == .current`), else the sync aborts;
///   - the remote copy is NEVER deleted. A remote archive that cannot be imported
///     is renamed aside; if even that fails it is copied into local Application
///     Support and syncing halts until the user resumes it;
///   - `NSFileVersion` conflict versions (two Macs wrote at once) are each merged
///     in before the winner is written: union by content hash, newest metadata wins;
///   - the whole merge is additive and runs in one database transaction per source.
///
/// The class is @MainActor so @Published state is only ever touched on the main
/// actor; the heavy work runs in a detached task and reports back a Sendable outcome.
@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()

    @Published private(set) var status = "Idle"
    @Published private(set) var syncing = false
    /// Non-nil when syncing has been stopped to protect the remote copy.
    @Published private(set) var haltReason: String? = UserDefaults.standard.string(forKey: ICloudSyncService.haltDefaultsKey)

    /// UserDefaults key persisting `haltReason` across launches.
    nonisolated static let haltDefaultsKey = "dat.icloud.syncHaltReason"

    /// Package folder name inside iCloud Drive > Clippy.
    nonisolated static let packageName = "clippy-sync.\(ClippyArchive.packageExtension)"
    /// Pre-package single-file archive, still imported when it is all that exists.
    nonisolated static let legacyFileName = "clippy-sync.toml"

    /// Tests (and the launch self-test) inject a local folder here instead of the
    /// real iCloud Drive path.
    private let rootOverride: URL?
    private let databaseOverride: ClipDatabase?
    private let probe: UbiquityProbe
    private let localFallback: URL
    private let downloadTimeout: TimeInterval

    init(rootOverride: URL? = nil, database: ClipDatabase? = nil,
         probe: UbiquityProbe = .system, localFallback: URL? = nil, downloadTimeout: TimeInterval = 60) {
        self.rootOverride = rootOverride
        self.databaseOverride = database
        self.probe = probe
        self.downloadTimeout = downloadTimeout
        self.localFallback = localFallback ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy/SyncQuarantine", isDirectory: true)
    }

    /// The local mirror of the user's iCloud Drive ("iCloud Drive > Clippy").
    /// nil when the user does not have iCloud Drive enabled.
    static var systemICloudDriveRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    private func driveRoot() -> URL? { rootOverride ?? Self.systemICloudDriveRoot }

    var isAvailable: Bool { driveRoot() != nil }

    private func syncDirectory() -> URL? {
        guard let root = driveRoot() else { return nil }
        let dir = root.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Called at launch and when the toggle flips. Safe no-op unless enabled.
    func startIfEnabled() {
        guard AppSettings.shared.iCloudSyncEnabled else { return }
        Task { await sync() }
    }

    /// Clear a halt after the user has looked at the problem; the next sync runs normally.
    func resumeAfterHalt() {
        haltReason = nil
        UserDefaults.standard.removeObject(forKey: Self.haltDefaultsKey)
    }

    func sync(force: Bool = false) async {
        guard force || AppSettings.shared.iCloudSyncEnabled else { return }
        guard !syncing else { return }
        if let haltReason {
            status = "Sync is stopped: \(haltReason)"
            return
        }
        guard let directory = syncDirectory() else {
            status = "iCloud Drive is not enabled on this Mac."
            return
        }
        syncing = true
        let database = databaseOverride ?? ClipDatabase.shared
        let probe = self.probe
        let fallback = localFallback
        let timeout = downloadTimeout

        let outcome: SyncOutcome = await Task.detached(priority: .utility) {
            do {
                return try await Self.run(directory: directory, database: database, probe: probe,
                                          localFallback: fallback, downloadTimeout: timeout)
            } catch {
                ClippyLog.error("iCloud sync failed: \(error)", category: ClippyLog.sync)
                return .failure(error.localizedDescription)
            }
        }.value

        syncing = false
        switch outcome {
        case .success(let merged):
            status = merged > 0 ? "Synced via iCloud Drive (merged \(merged) conflicting version(s))."
                                : "Synced via iCloud Drive."
            ClippyLog.info("iCloud sync succeeded", category: ClippyLog.sync)
        case .halted(let reason):
            haltReason = reason
            UserDefaults.standard.set(reason, forKey: Self.haltDefaultsKey)
            status = "Sync stopped: \(reason)"
        case .failure(let message):
            status = "Sync failed: \(message) " +
                "Check that iCloud Drive is enabled, the Clippy folder is writable, and you are not offline, then try Sync now."
        }
    }

    // MARK: - The sync itself (off the main actor)

    /// One full pull-merge-push cycle against `directory`. Static and free of
    /// actor state so tests can drive it against a local folder and a fake probe.
    nonisolated static func run(
        directory: URL, database: ClipDatabase, probe: UbiquityProbe,
        localFallback: URL, downloadTimeout: TimeInterval,
        pollInterval: TimeInterval = 0.25,
        move: (URL, URL) throws -> Void = ICloudFileAccess.coordinatedMove
    ) async throws -> SyncOutcome {
        let fileManager = FileManager.default
        let packageURL = directory.appendingPathComponent(packageName)
        let legacyURL = directory.appendingPathComponent(legacyFileName)
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("clippy-sync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        // 1. Never touch anything until it is fully local.
        try await ICloudFileAccess.waitUntilCurrent(packageURL, probe: probe, timeout: downloadTimeout, pollInterval: pollInterval)
        try await ICloudFileAccess.waitUntilCurrent(legacyURL, probe: probe, timeout: downloadTimeout, pollInterval: pollInterval)

        // 2. Merge the remote winner, then every conflicting version.
        var mergedConflicts: [NSFileVersion] = []
        if fileManager.fileExists(atPath: packageURL.path) {
            let snapshot = scratch.appendingPathComponent("remote.\(ClippyArchive.packageExtension)")
            try ICloudFileAccess.coordinatedRead(packageURL) { try fileManager.copyItem(at: $0, to: snapshot) }
            do {
                try ClippyArchive.importPackage(at: snapshot, into: database)
            } catch {
                ClippyLog.error("iCloud sync: unreadable remote archive: \(error)", category: ClippyLog.sync)
                switch ICloudFileAccess.quarantine(packageURL, localFallback: localFallback, move: move) {
                case .movedAside(let aside):
                    ClippyLog.info("iCloud sync: moved unreadable archive to \(aside.lastPathComponent)",
                                   category: ClippyLog.sync)
                case .copiedLocally(let local):
                    return .halted("the remote archive is unreadable and could not be set aside; "
                        + "it was left in iCloud untouched and copied to \(local.path)")
                case .failed:
                    return .halted("the remote archive is unreadable and could not be set aside or copied; "
                        + "it was left in iCloud untouched")
                }
            }
            for (index, version) in (NSFileVersion.unresolvedConflictVersionsOfItem(at: packageURL) ?? []).enumerated() {
                let copy = scratch.appendingPathComponent("conflict-\(index).\(ClippyArchive.packageExtension)")
                do {
                    try fileManager.copyItem(at: version.url, to: copy)
                    try ClippyArchive.importPackage(at: copy, into: database)
                    mergedConflicts.append(version)
                } catch {
                    // Left unresolved so the other Mac's data is not thrown away.
                    ClippyLog.error("iCloud sync: could not merge a conflicting version: \(error)",
                                    category: ClippyLog.sync)
                }
            }
        } else if fileManager.fileExists(atPath: legacyURL.path),
                  let text = try? String(contentsOf: legacyURL, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                _ = try ClippyArchive.importTOML(text, into: database)
            } catch {
                ClippyLog.error("iCloud sync: legacy archive unreadable, ignored (left in place): \(error)",
                                category: ClippyLog.sync)
            }
        }

        // 3. Export, then replace the remote under coordination, re-checking the
        // download state right before the write.
        let outgoing = scratch.appendingPathComponent("outgoing.\(ClippyArchive.packageExtension)")
        // The export omits sensitive clips (ClipDatabase.clipsGroupedByCategory default).
        try ClippyArchive.exportPackage(from: database, to: outgoing)
        try await ICloudFileAccess.waitUntilCurrent(packageURL, probe: probe, timeout: downloadTimeout, pollInterval: pollInterval)
        try ICloudFileAccess.coordinatedWrite(packageURL) { destination in
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: outgoing)
            } else {
                try fileManager.copyItem(at: outgoing, to: destination)
            }
            for version in mergedConflicts { version.isResolved = true }
            if !mergedConflicts.isEmpty { try NSFileVersion.removeOtherVersionsOfItem(at: destination) }
        }
        return .success(mergedConflicts: mergedConflicts.count)
    }
}

/// Result of one sync. Only Strings and Ints, so it is Sendable and crosses
/// back from the detached task.
enum SyncOutcome: Sendable, Equatable {
    case success(mergedConflicts: Int)
    /// Syncing must stop until the user resumes it (the remote copy is being protected).
    case halted(String)
    case failure(String)
}
