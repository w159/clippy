import Foundation

extension ClipStore {
    /// Save edited clip text. Returns true on success so the editor can keep
    /// its window open and surface the failure instead of silently discarding.
    @discardableResult
    func updateText(of clip: Clip, to newText: String) -> Bool {
        guard let id = clip.id else { return false }
        do {
            try database.updateClipText(id: id, newText: newText)
            return true
        } catch {
            ClippyLog.error("failed to update clip text: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// Save an edited image clip: store the new PNG, repoint the row, free the
    /// old files. Returns true on success so the editor can confirm.
    @discardableResult
    func updateImage(of clip: Clip, to pngData: Data) -> Bool {
        guard let id = clip.id else { return false }
        do {
            let stored = try database.media.store(pngData: pngData)
            try database.updateClipImage(id: id, stored: stored)
            return true
        } catch {
            ClippyLog.error("failed to save edited image: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// The on-disk URL of an image clip's full-resolution PNG, for the editor.
    func imageURL(for clip: Clip) -> URL? {
        clip.mediaFilename.map { database.media.url(for: $0) }
    }

    /// Save script stdout as a new clip in history. Distinct from the capture
    /// pipeline: no deduplication, source set to "Clippy Scripts".
    @discardableResult
    func saveScriptOutput(_ text: String) -> Bool {
        do {
            try database.insertTextClip(text)
            return true
        } catch {
            ClippyLog.error("failed to save script output: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// Set or clear a clip's custom title. Returns true on success so the
    /// editor can keep its window open and surface the failure.
    @discardableResult
    func renameClip(_ clip: Clip, userTitle: String?) -> Bool {
        guard let id = clip.id else { return false }
        // Treat empty string the same as nil (clear the custom title).
        let trimmed = userTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            try database.updateClipTitle(
                id: id, userTitle: trimmed?.isEmpty == true ? nil : trimmed)
            return true
        } catch {
            ClippyLog.error("failed to rename clip: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// The first category this clip belongs to, ordered by (sortOrder, createdAt).
    /// Used to pick the icon and accent color for pinned cards.
    func firstCategory(for clip: Clip) -> Category? {
        let ids = categoryIDs(for: clip)
        return categories.first { $0.id.map { ids.contains($0) } ?? false }
    }
}
