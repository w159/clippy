import Foundation

/// Persists the assistant conversation under Application Support (AI-12) so it
/// survives closing the panel. Owner-only permissions; Clear deletes the file.
struct AIConversationStore {
    struct Snapshot: Codable, Equatable {
        var version = 1
        var messages: [AssistantMessage]
        var transcript: AITranscript
    }

    /// Entries kept on disk and sent to the model; older ones are dropped.
    static let maxTranscriptEntries = 200

    let fileURL: URL

    init(fileURL: URL = AIConversationStore.defaultURL()) { self.fileURL = fileURL }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Clippy", isDirectory: true)
            .appendingPathComponent("assistant-conversation.json")
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        var snap = snapshot
        snap.transcript.trim(toLast: Self.maxTranscriptEntries)
        // Bubbles reference transcript offsets that trimming invalidates; Retry
        // only needs them for the live session, so drop them from the disk copy.
        for index in snap.messages.indices { snap.messages[index].transcriptStart = nil }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snap).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            ClippyLog.error("Could not persist assistant conversation: \(error.localizedDescription)",
                            category: ClippyLog.ai)
        }
    }

    func clear() { try? FileManager.default.removeItem(at: fileURL) }
}
