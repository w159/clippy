import Foundation

/// Unsaved editor state kept across quit or crash (EDT-01).
struct EditorDraft: Codable, Equatable {
    var clipID: Int64
    /// Editor text, nil for image editors (image edits are not drafted).
    var text: String
    var title: String
    /// Stored text the edits started from, to detect a changed clip on recovery.
    var baseText: String
    var savedAt: Date
}

/// Persists drafts as one JSON file. Drafts hold clip content, so the file is
/// written atomically with owner-only permissions and entries are removed as
/// soon as they are recovered, saved, or discarded. Never logs content.
///
/// `@unchecked Sendable`: all state is immutable; the injected `FileManager` is
/// `.default` outside tests, whose methods are documented as thread-safe.
final class EditorDraftStore: @unchecked Sendable {
    /// Location of the JSON file.
    let fileURL: URL
    private let fileManager: FileManager

    /// The app's draft store under Application Support/Clippy.
    static let shared: EditorDraftStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return EditorDraftStore(fileURL: base.appendingPathComponent("Clippy/EditorDrafts.json"))
    }()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// All stored drafts, oldest first. A missing or corrupt file yields none.
    func all() -> [EditorDraft] {
        guard let data = try? Data(contentsOf: fileURL),
              let drafts = try? JSONDecoder.draftDecoder.decode([EditorDraft].self, from: data)
        else { return [] }
        return drafts.sorted { $0.savedAt < $1.savedAt }
    }

    /// Inserts or replaces the draft for its clip. Returns false on write failure.
    @discardableResult
    func save(_ draft: EditorDraft) -> Bool {
        var drafts = all().filter { $0.clipID != draft.clipID }
        drafts.append(draft)
        return write(drafts)
    }

    /// Saves several drafts in one write.
    @discardableResult
    func save(_ newDrafts: [EditorDraft]) -> Bool {
        let ids = Set(newDrafts.map(\.clipID))
        return write(all().filter { !ids.contains($0.clipID) } + newDrafts)
    }

    /// Drops the draft for a clip (saved, discarded, or recovered).
    func remove(clipID: Int64) {
        let drafts = all()
        let kept = drafts.filter { $0.clipID != clipID }
        guard kept.count != drafts.count else { return }
        _ = write(kept)
    }

    func removeAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func write(_ drafts: [EditorDraft]) -> Bool {
        if drafts.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return true
        }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.draftEncoder.encode(drafts)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            ClippyLog.error("editor drafts: write failed: \(error)", category: ClippyLog.storage)
            return false
        }
    }
}

private extension JSONEncoder {
    static var draftEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var draftDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
