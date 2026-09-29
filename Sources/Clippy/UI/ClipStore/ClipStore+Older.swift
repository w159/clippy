import Foundation
import GRDB

extension ClipDatabase {
    /// Clips strictly older than the (createdAt, id) cursor, newest first. Keyset
    /// paging so a huge history costs the same per page.
    func olderClips(beforeCreatedAt createdAt: Date, id: Int64, limit: Int) throws -> [Clip] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { connection in
            try Clip.fetchAll(
                connection,
                sql: """
                    SELECT * FROM clips
                    WHERE createdAt < ? OR (createdAt = ? AND id < ?)
                    ORDER BY createdAt DESC, id DESC LIMIT ?
                    """,
                arguments: [createdAt, createdAt, id, limit])
        }
    }

    /// Which of `ids` still exist.
    func existingClipIDs(among ids: [Int64]) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { connection in
            let marks = ids.map { _ in "?" }.joined(separator: ", ")
            return Set(try Int64.fetchAll(connection, sql: "SELECT id FROM clips WHERE id IN (\(marks))",
                                          arguments: StatementArguments(ids)))
        }
    }
}

extension ClipStore {
    /// `recents` plus any older clips already paged in (browse mode list).
    func residentClips() -> [Clip] {
        guard !olderClips.isEmpty else { return recents }
        let known = Set(recents.compactMap(\.id))
        return recents + olderClips.filter { $0.id.map { !known.contains($0) } ?? false }
    }

    /// Loads up to `limit` clips older than `clip` (default: the oldest clip
    /// currently shown), appends them to `olderClips` and returns them. Reaches
    /// history beyond the 300-item resident window. Sets `hasMoreOlder`.
    @discardableResult
    func loadOlder(before clip: Clip? = nil, limit: Int = 100) async -> [Clip] {
        let cursor = await MainActor.run { () -> Clip? in
            clip ?? residentClips().min { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }
        }
        guard let cursor, let cursorID = cursor.id else { return [] }
        let database = self.database
        let page: [Clip]
        do {
            page = try await Task.detached(priority: .userInitiated) {
                try database.olderClips(beforeCreatedAt: cursor.createdAt, id: cursorID, limit: limit)
            }.value
        } catch {
            ClippyLog.error("Loading older clips failed: \(error)", category: ClippyLog.storage)
            return []
        }
        await MainActor.run {
            let known = Set(olderClips.compactMap(\.id))
            olderClips += page.filter { $0.id.map { !known.contains($0) } ?? false }
            hasMoreOlder = page.count == limit
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clips = residentClips() }
        }
        return page
    }

    /// Forgets paged-in history (call when the panel hides to release memory).
    func resetOlder() {
        guard !olderClips.isEmpty else { return }
        olderClips = []
        hasMoreOlder = true
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clips = recents }
    }

    /// Drops paged-in clips deleted or evicted since they were loaded.
    func pruneOlder() {
        let ids = olderClips.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let database = self.database
        Task.detached(priority: .utility) { [weak self] in
            guard let alive = try? database.existingClipIDs(among: ids) else { return }
            await MainActor.run { [weak self] in
                guard let self, alive.count != ids.count else { return }
                self.olderClips.removeAll { $0.id.map { !alive.contains($0) } ?? true }
                if self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.clips = self.residentClips()
                }
            }
        }
    }
}
