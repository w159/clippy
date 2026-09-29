import Foundation

/// Persistence for snippets, stored at `Application Support/Clippy/snippets.json`
/// through `JSONFileStore` (lossy decode, corrupt quarantine, atomic throwing saves).
@MainActor
final class SnippetStore {
    /// Shared store at the default location.
    static let shared = SnippetStore(fileURL: SnippetStore.defaultURL)

    /// `~/Library/Application Support/Clippy/snippets.json`.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clippy", isDirectory: true).appendingPathComponent("snippets.json")
    }

    private let store: JSONFileStore<Snippet>

    /// Opens (creating the parent folder if needed) the store at `fileURL`.
    init(fileURL: URL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = JSONFileStore<Snippet>(fileURL: fileURL, decodeStrategy: .lossy, configureEncoder: { encoder in
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
        }, configureDecoder: { $0.dateDecodingStrategy = .iso8601 })
    }

    /// All snippets in stored order.
    var snippets: [Snippet] { store.items }
    /// Set when the file could not be read; saving is paused until resolved.
    var loadError: JSONFileStoreError? { store.loadError }
    /// Most recent failed save from a non-throwing call.
    var saveError: Error? { store.saveError }

    /// Adds a snippet.
    func add(_ snippet: Snippet) throws { try store.tryAdd(snippet) }
    /// Replaces the snippet with the same id.
    func update(_ snippet: Snippet) throws { try store.tryUpdate(snippet) }
    /// Removes a snippet.
    func delete(id: UUID) throws { try store.tryDelete(id: id) }

    /// Adds a copy titled "<title> copy" with an empty abbreviation (so triggers stay unique).
    @discardableResult
    func duplicate(id: UUID) throws -> Snippet? {
        guard let source = snippets.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.title = source.displayName + " copy"
        copy.abbreviation = ""
        copy.useCount = 0
        copy.createdAt = Date()
        try store.tryAdd(copy)
        return copy
    }

    /// Increments the use counter; a failed save is recorded in `saveError`.
    func recordUse(id: UUID) {
        guard var snippet = snippets.first(where: { $0.id == id }) else { return }
        snippet.useCount += 1
        store.update(snippet)
    }

    /// Distinct non-empty folder names, sorted.
    var folders: [String] { Array(Set(snippets.map(\.folder).filter { !$0.isEmpty })).sorted() }

    // MARK: - Import / export

    /// Pretty JSON for `items` (all snippets by default).
    func exportJSON(_ items: [Snippet]? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items ?? snippets)
    }

    /// Imports snippets from exported JSON, giving each a fresh id and skipping any whose
    /// non-empty abbreviation already exists. Returns how many were added.
    @discardableResult
    func importJSON(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = try decoder.decode([Snippet].self, from: data)
        var known = Set(snippets.map(\.abbreviation).filter { !$0.isEmpty })
        var added = 0
        for var snippet in incoming {
            if !snippet.abbreviation.isEmpty, !known.insert(snippet.abbreviation).inserted { continue }
            snippet.id = UUID()
            try store.tryAdd(snippet)
            added += 1
        }
        return added
    }
}
