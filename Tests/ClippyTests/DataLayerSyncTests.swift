import GRDB
import XCTest
@testable import Clippy

/// DAT-03/04/05/10: iCloud download wait, non-destructive quarantine, and the
/// external-change watcher's advance-only-on-success rule.
@MainActor
final class DataLayerSyncTests: XCTestCase {

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private final class Counter { var value = 0 }

    private func probe(statuses: [URLUbiquitousItemDownloadingStatus?], started: Counter? = nil) -> UbiquityProbe {
        var remaining = statuses
        return UbiquityProbe(
            isUbiquitous: { _ in true },
            downloadStatus: { _ in remaining.count > 1 ? remaining.removeFirst() : remaining.first ?? nil },
            startDownload: { _ in started?.value += 1 })
    }

    // MARK: - Download wait (DAT-04)

    func testWaitReturnsOnlyOnceStatusIsCurrentAndAsksICloudToDownload() async throws {
        let dir = try tempDir("dl")
        let url = dir.appendingPathComponent("a.bin")
        try Data("x".utf8).write(to: url)
        let started = Counter()
        let fake = probe(statuses: [.notDownloaded, .notDownloaded, .current], started: started)
        try await ICloudFileAccess.waitUntilCurrent(url, probe: fake, timeout: 5, pollInterval: 0.01)
        XCTAssertEqual(started.value, 1)
    }

    func testWaitTimesOutInsteadOfLettingACallerWriteOverAnUndownloadedItem() async throws {
        let dir = try tempDir("dl-timeout")
        let url = dir.appendingPathComponent("a.bin")
        try Data("x".utf8).write(to: url)
        let fake = probe(statuses: [.notDownloaded])
        do {
            try await ICloudFileAccess.waitUntilCurrent(url, probe: fake, timeout: 0.1, pollInterval: 0.01)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ICloudSyncError, .downloadTimedOut("a.bin"))
        }
    }

    func testWaitIsImmediateForLocalOrAbsentItems() async throws {
        let dir = try tempDir("dl-local")
        let local = dir.appendingPathComponent("local.bin")
        try Data("x".utf8).write(to: local)
        let notUbiquitous = UbiquityProbe(isUbiquitous: { _ in false }, downloadStatus: { _ in nil }, startDownload: { _ in })
        try await ICloudFileAccess.waitUntilCurrent(local, probe: notUbiquitous, timeout: 0.05, pollInterval: 0.01)
        try await ICloudFileAccess.waitUntilCurrent(dir.appendingPathComponent("absent"), probe: notUbiquitous,
                                                    timeout: 0.05, pollInterval: 0.01)
    }

    func testSyncWritesNothingWhenTheRemoteNeverFinishesDownloading() async throws {
        let dir = try tempDir("sync-dl")
        let package = dir.appendingPathComponent(ICloudSyncService.packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: package.appendingPathComponent("marker"))
        let db = try makeTestDatabase(self)
        do {
            _ = try await ICloudSyncService.run(
                directory: dir, database: db, probe: probe(statuses: [.notDownloaded]),
                localFallback: try tempDir("fb"), downloadTimeout: 0.1, pollInterval: 0.01)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ICloudSyncError, .downloadTimedOut(ICloudSyncService.packageName))
        }
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("marker")), Data("remote".utf8),
                       "the remote copy is untouched")
    }

    // MARK: - Quarantine (DAT-03)

    private struct MoveFailed: Error {}

    func testFailedQuarantineMoveCopiesLocallyAndNeverDeletesTheRemote() throws {
        let dir = try tempDir("q")
        let remote = dir.appendingPathComponent("archive.clippyarchive")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: remote.appendingPathComponent("clippy.toml"))
        let fallback = try tempDir("q-local")

        let outcome = ICloudFileAccess.quarantine(remote, localFallback: fallback, move: { _, _ in throw MoveFailed() })

        guard case .copiedLocally(let local) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.path), "remote must never be deleted")
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("clippy.toml")), Data("precious".utf8))
    }

    func testSyncHaltsAndLeavesAnUnreadableRemoteInPlaceWhenItCannotBeSetAside() async throws {
        let dir = try tempDir("halt")
        let package = dir.appendingPathComponent(ICloudSyncService.packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("not toml at all ][".utf8).write(to: package.appendingPathComponent("clippy.toml"))
        let db = try makeTestDatabase(self)
        let fallback = try tempDir("halt-local")

        let outcome = try await ICloudSyncService.run(
            directory: dir, database: db, probe: probe(statuses: [.current]), localFallback: fallback,
            downloadTimeout: 1, pollInterval: 0.01, move: { _, _ in throw MoveFailed() })

        guard case .halted = outcome else { return XCTFail("expected halt, got \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("clippy.toml")), Data("not toml at all ][".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fallback.path).isEmpty)
    }

    func testSyncMovesAnUnreadableRemoteAsideAndWritesAGoodOne() async throws {
        let dir = try tempDir("aside")
        let package = dir.appendingPathComponent(ICloudSyncService.packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("garbage ][".utf8).write(to: package.appendingPathComponent("clippy.toml"))
        let db = try makeTestDatabase(self)
        try db.insertTextClip("local clip", cap: 0)
        let category = try db.createCategory(named: "Sync", colorHex: "#1", iconKind: .symbol, iconValue: "t")
        try db.setClip(try XCTUnwrap(db.allClips().first?.id), inCategory: try XCTUnwrap(category.id), true)

        let outcome = try await ICloudSyncService.run(
            directory: dir, database: db, probe: probe(statuses: [.current]), localFallback: try tempDir("l"),
            downloadTimeout: 1, pollInterval: 0.01)

        XCTAssertEqual(outcome, .success(mergedConflicts: 0))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.contains(".unreadable-") }, "bad archive kept, not deleted")
        let toml = try String(contentsOf: package.appendingPathComponent("clippy.toml"))
        XCTAssertTrue(toml.contains("local clip"))
    }

    func testTwoMacsConvergeThroughTheSharedPackage() async throws {
        let dir = try tempDir("two")
        let macA = try makeTestDatabase(self)
        let macB = try makeTestDatabase(self)
        for (db, text) in [(macA, "from A"), (macB, "from B")] {
            try db.insertTextClip(text, cap: 0)
            let category = try db.createCategory(named: "Shared", colorHex: "#1", iconKind: .symbol, iconValue: "t")
            try db.setClip(try XCTUnwrap(db.allClips().first?.id), inCategory: try XCTUnwrap(category.id), true)
        }
        let local = probe(statuses: [.current])
        for db in [macA, macB, macA] {
            _ = try await ICloudSyncService.run(directory: dir, database: db, probe: local,
                                                localFallback: try tempDir("f"), downloadTimeout: 1, pollInterval: 0.01)
        }
        for db in [macA, macB] {
            XCTAssertEqual(Set(try db.allClips().map(\.contentText)), ["from A", "from B"])
        }
    }

    // MARK: - ExternalChangeWatcher (DAT-10)

    func testVersionAdvancesOnlyAfterASuccessfulRefresh() throws {
        let database = try makeTestDatabase(self)
        var shouldFail = true
        var notifyCalls = 0
        let watcher = ExternalChangeWatcher(database: database, fileStoreReloaders: [], notifyChanges: {
            notifyCalls += 1
            if shouldFail { throw NSError(domain: "test", code: 1) }
        })
        watcher.start()
        let other = try DatabaseQueue(path: database.databaseURL.path)
        try other.write { db in
            try db.execute(sql: """
                INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind)
                VALUES ('external', 'public.utf8-plain-text', '2026-09-16 12:00:00.000', 'text')
                """)
        }
        XCTAssertFalse(watcher.tick(), "refresh failed")
        XCTAssertFalse(watcher.tick())
        XCTAssertEqual(notifyCalls, 2, "the change must be retried on the next tick, not forgotten")
        shouldFail = false
        XCTAssertTrue(watcher.tick(), "retry succeeds once notify works")
        XCTAssertFalse(watcher.tick(), "and only fires once")
    }

    func testDataVersionIgnoresOwnWritesOnThePool() throws {
        let database = try makeTestDatabase(self)
        let before = try database.dataVersion()
        try database.insertTextClip("own write", cap: 0)
        XCTAssertEqual(try database.dataVersion(), before)
    }
}
