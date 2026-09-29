import Foundation
import GRDB

// Backup/restore snapshots, VACUUM, integrity checking and orphaned-media
// reporting (DAT-15). UI-free: Settings can call these directly.

/// One on-disk backup: a folder holding `clippy.sqlite` and a `media/` copy.
struct BackupSnapshot: Equatable, Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let createdAt: Date
    /// Size of the database file inside the snapshot.
    let databaseBytes: Int64

    var databaseURL: URL { url.appendingPathComponent(ClipDatabase.snapshotDatabaseName) }
    var mediaURL: URL { url.appendingPathComponent("media", isDirectory: true) }
}

struct IntegrityReport: Equatable {
    /// True only when SQLite, foreign-key and FTS checks all came back clean.
    var isHealthy: Bool { problems.isEmpty }
    var problems: [String]
}

struct VacuumReport: Equatable {
    var bytesBefore: Int64
    var bytesAfter: Int64
    var reclaimed: Int64 { max(0, bytesBefore - bytesAfter) }
}

struct OrphanMediaReport: Equatable {
    /// Files in the media folder no clip references.
    var orphanedFiles: [String]
    var orphanedBytes: Int64
    /// Filenames a clip references that are missing on disk.
    var missingFiles: [String]
    /// Orphans actually deleted (0 for a report-only pass).
    var removedCount: Int
}

enum BackupError: Error, Equatable, LocalizedError {
    case snapshotUnhealthy([String])
    case snapshotMissing

    var errorDescription: String? {
        switch self {
        case .snapshotUnhealthy(let problems):
            return "The backup failed its integrity check and was not restored: \(problems.joined(separator: "; "))"
        case .snapshotMissing: return "The backup no longer exists on disk."
        }
    }
}

extension ClipDatabase {
    static let snapshotDatabaseName = "clippy.sqlite"

    /// Where snapshots live: `Backups/` next to the database file.
    var backupsDirectory: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: - Integrity / vacuum

    /// `PRAGMA integrity_check`, `foreign_key_check` and the FTS index check.
    func integrityCheck() throws -> IntegrityReport {
        try Self.integrityProblems(in: dbQueue)
    }

    private static func integrityProblems(in reader: DatabaseReader) throws -> IntegrityReport {
        var problems: [String] = []
        try reader.read { db in
            let rows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            if rows != ["ok"] { problems += rows }
            let fk = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            for row in fk {
                let table: String = row[0]
                problems.append("foreign key violation in \(table)")
            }
        }
        // The FTS check writes nothing but must run on a writable statement.
        if let writer = reader as? DatabaseWriter {
            do {
                try writer.write { db in
                    try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('integrity-check')")
                }
            } catch {
                problems.append("search index: \(error)")
            }
        }
        return IntegrityReport(problems: problems)
    }

    /// Rebuild the database file to reclaim free pages.
    func vacuum() throws -> VacuumReport {
        // WAL mode: VACUUM writes the rebuilt file into the WAL, so the file only
        // shrinks once that is checkpointed. Measure both ends after a truncating
        // checkpoint, otherwise "after" includes the fresh WAL and looks larger.
        checkpointWAL()
        let before = databaseFootprint()
        try dbQueue.vacuum()
        checkpointWAL()
        return VacuumReport(bytesBefore: before, bytesAfter: databaseFootprint())
    }

    /// Fold the WAL into the main file and truncate it. Best effort: the in-memory
    /// recovery sentinel has no WAL, and a concurrent reader can defer truncation.
    private func checkpointWAL() {
        try? dbQueue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    private func databaseFootprint() -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = databaseURL.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }

    // MARK: - Backups

    /// Snapshot the database (consistent, via SQLite's online backup API) and a
    /// copy of the media folder into `Backups/clippy-<timestamp>/`.
    @discardableResult
    func createBackup(now: Date = Date()) throws -> BackupSnapshot {
        let fm = FileManager.default
        let stamp = Self.snapshotStamp(now)
        var folder = backupsDirectory.appendingPathComponent("clippy-\(stamp)", isDirectory: true)
        var attempt = 2
        while fm.fileExists(atPath: folder.path) {
            folder = backupsDirectory.appendingPathComponent("clippy-\(stamp)-\(attempt)", isDirectory: true)
            attempt += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let destination = try DatabaseQueue(path: folder.appendingPathComponent(Self.snapshotDatabaseName).path)
            try dbQueue.backup(to: destination)
            // The backup inherits WAL mode from the live database. A snapshot must
            // be one self-contained file: no -wal/-shm sidecars to lose in a copy,
            // and openable read-only.
            try destination.writeWithoutTransaction { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
            }
            try destination.close()
            // APFS clones these, so the copy is near-instant and shares blocks.
            try fm.copyItem(at: media.directory, to: folder.appendingPathComponent("media", isDirectory: true))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        guard let snapshot = Self.readSnapshot(at: folder) else { throw BackupError.snapshotMissing }
        return snapshot
    }

    /// Existing snapshots, newest first.
    func listBackups() -> [BackupSnapshot] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap(Self.readSnapshot(at:)).sorted { $0.createdAt > $1.createdAt }
    }

    func deleteBackup(_ snapshot: BackupSnapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    /// Replace the live database with a snapshot. The snapshot is integrity
    /// checked first (an unhealthy one is refused), and the current state is
    /// itself snapshotted so a restore is always reversible. Observers refresh.
    func restoreBackup(_ snapshot: BackupSnapshot) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.databaseURL.path) else { throw BackupError.snapshotMissing }
        // Not read-only: a snapshot from an older build may still be in WAL mode,
        // and a read-only connection cannot create the sidecar files WAL needs.
        let source = try DatabaseQueue(path: snapshot.databaseURL.path)
        let report = try Self.integrityProblems(in: source)
        guard report.isHealthy else { throw BackupError.snapshotUnhealthy(report.problems) }

        try createBackup()  // safety net taken before anything is overwritten
        try source.backup(to: dbQueue)
        // A snapshot from an older build may predate newer migrations.
        try Self.makeMigrator().migrate(dbQueue)
        if fm.fileExists(atPath: snapshot.mediaURL.path) {
            for name in (try? fm.contentsOfDirectory(atPath: snapshot.mediaURL.path)) ?? [] {
                let target = media.url(for: name)
                if !fm.fileExists(atPath: target.path) {
                    try fm.copyItem(at: snapshot.mediaURL.appendingPathComponent(name), to: target)
                }
            }
        }
        cachedStarterCategoryID = nil
        try notifyExternalChanges()
    }

    private static func snapshotStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func readSnapshot(at folder: URL) -> BackupSnapshot? {
        let db = folder.appendingPathComponent(snapshotDatabaseName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: db.path),
              let created = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date else { return nil }
        return BackupSnapshot(url: folder, createdAt: created,
                              databaseBytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
    }

    // MARK: - Orphaned media

    /// Compare the media folder with what clips reference. With `remove` false
    /// it only reports; with true it deletes the orphans (files younger than a
    /// minute are always spared: their row may still be in flight).
    @discardableResult
    func orphanMediaReport(remove: Bool = false) throws -> OrphanMediaReport {
        let fm = FileManager.default
        let referenced = try referencedMediaFilenames()
        let onDisk = Set((try? fm.contentsOfDirectory(atPath: media.directory.path)) ?? [])
        var orphans: [String] = []
        var bytes: Int64 = 0
        for name in onDisk.subtracting(referenced).sorted() {
            let url = media.url(for: name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let modified = values?.contentModificationDate, Date().timeIntervalSince(modified) < 60 { continue }
            orphans.append(name)
            bytes += Int64(values?.fileSize ?? 0)
        }
        if remove { media.delete(filenames: orphans) }
        return OrphanMediaReport(
            orphanedFiles: orphans, orphanedBytes: bytes,
            missingFiles: referenced.subtracting(onDisk).sorted(),
            removedCount: remove ? orphans.count : 0)
    }
}
