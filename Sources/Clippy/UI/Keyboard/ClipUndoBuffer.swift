import Foundation
import AppKit

/// A deleted clip captured before deletion so it can be restored (KEY-11).
struct DeletedClipSnapshot {
    /// The full row, including its original id, dates and titles.
    let clip: Clip
    /// Category memberships at deletion time.
    let categoryIDs: Set<Int64>
    /// Bytes of the media files the delete removes from disk, by filename.
    let media: [String: Data]
}

/// In-memory, capped undo stack for deletes. Each entry is one delete action
/// (a single clip or a whole batch). Never persisted: it holds clip content, so
/// it is cleared when the app quits. Main-thread use.
@MainActor
final class ClipUndoBuffer {
    /// Shared buffer used by the panel.
    static let shared = ClipUndoBuffer(observesTermination: true)

    /// Largest media payload snapshotted per clip; bigger clips are deleted
    /// without an undo entry rather than held in memory.
    static let maxMediaBytes = 32 * 1024 * 1024

    private(set) var steps: [[DeletedClipSnapshot]] = []
    let capacity: Int
    private var terminationObserver: NSObjectProtocol?

    init(capacity: Int = 20, observesTermination: Bool = false) {
        self.capacity = max(1, capacity)
        if observesTermination {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.clear() } }
        }
    }

    isolated deinit { terminationObserver.map(NotificationCenter.default.removeObserver) }

    var isEmpty: Bool { steps.isEmpty }
    var count: Int { steps.count }

    /// Captures `clip` (with its category memberships and media bytes) before the
    /// caller deletes it. Nil when the media exceeds `maxMediaBytes` or cannot be read.
    static func snapshot(of clip: Clip, categoryIDs: Set<Int64>, media: MediaStore) -> DeletedClipSnapshot? {
        var files: [String: Data] = [:]
        var total = 0
        for name in clip.mediaFilenames where !name.isEmpty {
            let url = media.url(for: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            guard total <= maxMediaBytes, let data = try? Data(contentsOf: url) else { return nil }
            files[name] = data
        }
        return DeletedClipSnapshot(clip: clip, categoryIDs: categoryIDs, media: files)
    }

    /// Records one delete action. Oldest entries fall off past `capacity`.
    func record(_ snapshots: [DeletedClipSnapshot]) {
        guard !snapshots.isEmpty else { return }
        steps.append(snapshots)
        if steps.count > capacity { steps.removeFirst(steps.count - capacity) }
    }

    /// Removes and returns the most recent delete action.
    func popLast() -> [DeletedClipSnapshot]? { steps.popLast() }

    func clear() { steps.removeAll() }

    /// Re-inserts the snapshotted clips through the database's public APIs:
    /// media files first, then the row (a fresh id when the old one was reused),
    /// then category memberships (a category deleted meanwhile is skipped).
    /// Returns the number of clips restored.
    @discardableResult
    static func restore(_ snapshots: [DeletedClipSnapshot], into database: ClipDatabase) throws -> Int {
        var restored = 0
        for snap in snapshots {
            for (name, data) in snap.media {
                let url = database.media.url(for: name)
                if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            }
            var clip = snap.clip
            if let id = clip.id, try database.clipExists(id: id) { clip.id = nil }
            try database.dbQueue.write { connection in try clip.insert(connection) }
            guard let newID = clip.id else { continue }
            for categoryID in snap.categoryIDs {
                do { try database.setClip(newID, inCategory: categoryID, true) } catch {
                    ClippyLog.error("undo delete: category restore failed: \(error)", category: ClippyLog.storage)
                }
            }
            restored += 1
        }
        return restored
    }
}
