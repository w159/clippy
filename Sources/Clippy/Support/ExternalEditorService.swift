import AppKit

/// Round-trips a text clip through an external editor. The clip's text is
/// written to a temp file, the file opens in Sublime Text (or the system's
/// default app for plain text when Sublime is not installed), and a
/// file-system watcher saves every on-disk change back to the clip. The
/// watcher survives atomic saves (editors replace the file via rename) by
/// re-opening its file descriptor when the inode changes.
@MainActor
final class ExternalEditorService {
    static let shared = ExternalEditorService()

    private struct Session {
        let clipID: Int64
        let clip: Clip
        let store: ClipStore
        let url: URL
        var lastKnownText: String
        var source: DispatchSourceFileSystemObject?
    }

    private var sessions: [Int64: Session] = [:]

    /// Bundle ids for Sublime Text, newest first.
    private static let sublimeBundleIDs = ["com.sublimetext.4", "com.sublimetext.3"]

    private init() {}

    /// URL of the preferred external editor app, when one is installed.
    private var sublimeURL: URL? {
        for bundleID in Self.sublimeBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        return nil
    }

    /// Menu label for the external-edit action, naming the app that will open.
    var menuTitle: String {
        if let url = sublimeURL {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return "Edit in \(name)..."
        }
        return "Edit in External Editor..."
    }

    /// Opens `clip` in the external editor and starts syncing saves back.
    /// Re-invoking for a clip that already has a session just re-opens the
    /// same file, so the editor focuses the existing document.
    func edit(clip: Clip, store: ClipStore) {
        guard clip.contentKind == .text, let clipID = clip.id else { return }

        if let existing = sessions[clipID] {
            openInEditor(existing.url)
            return
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyExternalEdit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            ClippyLog.error("external edit: cannot create temp dir: \(error)", category: ClippyLog.storage)
            return
        }

        // Human-readable filename so the editor tab is tellable apart; the id
        // prefix keeps names unique when titles collide.
        let safeTitle = clip.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .prefix(40)
        let url = dir.appendingPathComponent("clip-\(clipID)-\(safeTitle).txt")

        do {
            try clip.contentText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ClippyLog.error("external edit: cannot write temp file: \(error)", category: ClippyLog.storage)
            return
        }

        var session = Session(
            clipID: clipID,
            clip: clip,
            store: store,
            url: url,
            lastKnownText: clip.contentText,
            source: nil
        )
        session.source = makeWatcher(for: url, clipID: clipID)
        sessions[clipID] = session

        openInEditor(url)
    }

    private func openInEditor(_ url: URL) {
        if let appURL = sublimeURL {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - File watching

    /// Watches the temp file and pushes on-disk changes back into the clip.
    /// Returns nil when the file cannot be opened for watching.
    private func makeWatcher(for url: URL, clipID: Int64) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            ClippyLog.error("external edit: cannot watch \(url.lastPathComponent)", category: ClippyLog.storage)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            // Atomic saves replace the file (rename/delete on the old inode);
            // the fd now points at the orphaned inode, so re-arm on the path.
            if event.contains(.rename) || event.contains(.delete) {
                source.cancel()
                // Give the editor a beat to finish the atomic replace before
                // reopening; the new watcher reads the fresh content.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    MainActor.assumeIsolated {
                        guard var session = self.sessions[clipID] else { return }
                        session.source = self.makeWatcher(for: session.url, clipID: clipID)
                        self.sessions[clipID] = session
                        self.syncFromDisk(clipID: clipID)
                    }
                }
            } else {
                MainActor.assumeIsolated {
                    self.syncFromDisk(clipID: clipID)
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return source
    }

    /// Reads the temp file and saves the text back to the clip when it changed.
    private func syncFromDisk(clipID: Int64) {
        guard var session = sessions[clipID] else { return }
        guard let text = try? String(contentsOf: session.url, encoding: .utf8) else { return }
        guard text != session.lastKnownText else { return }
        session.lastKnownText = text
        sessions[clipID] = session
        if session.store.updateText(of: session.clip, to: text) {
            ClippyLog.info("external edit: clip \(clipID) synced (\(text.count) chars)", category: ClippyLog.storage)
        }
    }
}
