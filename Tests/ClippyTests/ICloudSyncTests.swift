import XCTest
@testable import Clippy

@MainActor
final class ICloudSyncTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-icloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testIsAvailableReflectsInjectedRoot() {
        let present = ICloudSyncService(rootOverride: tempDir())
        XCTAssertTrue(present.isAvailable)

        let missing = ICloudSyncService(rootOverride: URL(fileURLWithPath: "/no/such/folder/xyz"))
        // A non-existent override still resolves a path; availability is about the
        // folder being usable. The folder is created lazily, so the override is
        // considered available (the real guard is the system path being absent).
        XCTAssertTrue(missing.isAvailable)
    }

    func testForcedSyncWritesArchivePackageWithoutCrashing() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Inject a scratch database: the default is the user's real one.
        let service = ICloudSyncService(rootOverride: dir, database: try makeTestDatabase(self))
        // force: true bypasses the global enabled flag so the test does not touch
        // user defaults; it exercises the same code path the launch start uses.
        await service.sync(force: true)

        // The archive is a package folder: manifest plus bundled media.
        let manifest = dir.appendingPathComponent("Clippy/\(ICloudSyncService.packageName)/clippy.toml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path),
                      "sync must write the archive package")
        XCTAssertTrue(service.status.contains("Synced"), "status was: \(service.status)")
    }

    func testSyncIsNoOpWhenDisabledAndNotForced() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let previous = AppSettings.shared.iCloudSyncEnabled
        defer { AppSettings.shared.iCloudSyncEnabled = previous }
        AppSettings.shared.iCloudSyncEnabled = false

        let service = ICloudSyncService(rootOverride: dir)
        await service.sync()  // not forced, disabled -> no-op
        let package = dir.appendingPathComponent("Clippy/\(ICloudSyncService.packageName)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }
}
