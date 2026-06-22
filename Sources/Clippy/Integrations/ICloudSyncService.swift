import Foundation

/// iCloud sync that actually works for a Developer-ID / Sparkle-distributed app.
///
/// CloudKit is intentionally NOT used: it requires App Store or development
/// provisioning that a directly-distributed (Developer ID) app cannot have, and
/// touching it without the entitlement crashes the process. Instead this writes
/// Clippy's archive into the user's iCloud Drive folder as a regular file. A
/// non-sandboxed app can read and write there with no entitlement, and iCloud
/// uploads/downloads it across the user's Macs.
///
/// Merge is non-destructive: it reuses ClippyArchive's TOML import (add/update,
/// never clear), so two devices converge instead of clobbering each other.
///
/// The class is @MainActor so @Published state is only ever touched on the main
/// actor. Audit finding: the DB/TOML export and file IO used to run inline on the
/// main thread. That heavy work now runs in a Task.detached that captures only
/// the Sendable file URL (pullIfPresent is static so it does not capture self),
/// and the result is applied back on the main actor after `await`.
@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()

    @Published private(set) var status = "Idle"
    @Published private(set) var syncing = false

    private let syncFileName = "clippy-sync.toml"

    /// Tests (and the launch self-test) inject a local folder here instead of the
    /// real iCloud Drive path.
    private let rootOverride: URL?

    init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
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

    private func syncFileURL() -> URL? {
        guard let root = driveRoot() else { return nil }
        let dir = root.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(syncFileName)
    }

    /// Called at launch and when the toggle flips. Safe no-op unless enabled.
    func startIfEnabled() {
        guard AppSettings.shared.iCloudSyncEnabled else { return }
        Task { await sync() }
    }

    func sync(force: Bool = false) async {
        guard force || AppSettings.shared.iCloudSyncEnabled else { return }
        guard !syncing else { return }
        guard let url = syncFileURL() else {
            status = "iCloud Drive is not enabled on this Mac."
            return
        }
        syncing = true

        // Heavy DB/TOML work off the main actor. The detached task captures only
        // the Sendable `url`: pullIfPresent is static (no `self` capture) and the
        // archive/database calls go through global singletons. SyncOutcome is
        // Sendable so it can cross back via .value, after which we resume on the
        // main actor and mutate @Published state directly.
        let outcome: SyncOutcome = await Task.detached(priority: .utility) {
            do {
                try await Self.pullIfPresent(url)
                let toml = try ClippyArchive.exportTOML(from: ClipDatabase.shared)
                try toml.write(to: url, atomically: true, encoding: .utf8)
                return .success
            } catch {
                // Log the full error off-main where the Error object is still in
                // scope; carry only the localizedDescription string back so the
                // outcome type stays Sendable.
                ClippyLog.error("iCloud sync failed: \(error)", category: ClippyLog.sync)
                return .failure(error.localizedDescription)
            }
        }.value

        syncing = false
        switch outcome {
        case .success:
            status = "Synced via iCloud Drive."
            ClippyLog.info("iCloud sync succeeded", category: ClippyLog.sync)
        case .failure(let message):
            // Audit finding: include the underlying error and a short remediation
            // hint instead of a bare "Sync failed:" line, so the user has
            // something actionable in the red inline status.
            status = "Sync failed: \(message) " +
                "Check that iCloud Drive is enabled, the Clippy folder is writable, and you are not offline, then try Sync now."
        }
    }

    private static func pullIfPresent(_ url: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // iCloud keeps a not-yet-downloaded item as a hidden ".name.icloud"
            // placeholder. Only wait when one actually exists; otherwise there is
            // nothing remote to pull and we return immediately (no first-sync stall).
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            guard fm.fileExists(atPath: placeholder.path) else { return }
            try? fm.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<10 where !fm.fileExists(atPath: url.path) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard fm.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try ClippyArchive.importTOML(text, into: ClipDatabase.shared)
    }
}

/// Internal result type for the off-main sync workload. Carries only a String
/// (the localized error description) on failure so the type is Sendable and can
/// cross the isolation boundary back through Task.value.
private enum SyncOutcome: Sendable {
    case success
    case failure(String)
}