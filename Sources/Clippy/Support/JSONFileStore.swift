import Foundation

/// Why a JSON store could not be used as loaded.
enum JSONFileStoreError: Error, Equatable, LocalizedError {
    /// The file exists but is not valid JSON for `[Element]`. `quarantinedTo` is
    /// where the untouched bytes were moved (nil when even that failed, in which
    /// case the original file is still in place).
    case corrupt(reason: String, quarantinedTo: URL?)
    /// A save was refused because a load error has not been resolved yet.
    case unresolvedLoadError

    var errorDescription: String? {
        switch self {
        case .corrupt(let reason, let url):
            let kept = url.map { " Your original file was kept as \($0.lastPathComponent)." } ?? ""
            return "The saved data could not be read (\(reason)).\(kept)"
        case .unresolvedLoadError:
            return "Saving is paused because the saved data could not be read. Resolve the load error first."
        }
    }
}

/// A generic, file-backed JSON store for an ordered list of Codable + Identifiable values.
///
/// Responsibilities:
///   - Load from / save to a single JSON file atomically.
///   - Expose add / update / delete / move operations that persist after every mutation.
///   - Forward encoder/decoder configuration to the caller so date strategies,
///     custom keys, etc. live in the wrapper, not here.
///
/// Failure handling (DAT-01/02): a file that fails to decode is NEVER overwritten.
/// Its bytes are moved to `<name>.corrupt-<ISO date>`, `loadError` is set for the
/// UI, and every save is refused until `resolveLoadError()` is called. Saves
/// throw and write atomically; the non-throwing mutators record the failure in
/// `saveError` instead of swallowing it.
///
/// Non-responsibilities (stay in the wrapper):
///   - sortOrder renumbering (requires knowledge of the element's fields).
///   - Migration (one-time data fixups belong to the store that owns the schema).
///   - Seeding (default-data logic is application-level, not persistence-level).
final class JSONFileStore<Element: Codable & Identifiable> {

    /// How elements that fail to decode are treated.
    enum DecodeStrategy {
        /// Any bad element fails the whole load (-> `loadError`).
        case strict
        /// Bad elements are skipped so one damaged entry cannot take the rest
        /// with it (SCR-07). The original file is preserved as
        /// `<name>.lossy-<ISO date>` before anything is saved over it.
        case lossy
    }

    // MARK: - State

    private(set) var items: [Element] = []

    /// Set when the file could not be decoded; nil when loaded cleanly.
    private(set) var loadError: JSONFileStoreError?
    /// The most recent failed save from a non-throwing mutator; cleared by a good save.
    private(set) var saveError: Error?
    /// Elements skipped by the last lossy load.
    private(set) var skippedElementCount = 0

    private let fileURL: URL
    private let strategy: DecodeStrategy
    private let configureEncoder: ((JSONEncoder) -> Void)?
    private let configureDecoder: ((JSONDecoder) -> Void)?

    /// Modification date of the file as of our last load or save. Anything newer
    /// was written by somebody else - in practice the MCP server process. See
    /// `reloadIfModifiedExternally`.
    private var lastSyncedModification: Date?

    // MARK: - Init

    init(fileURL: URL,
         decodeStrategy: DecodeStrategy = .strict,
         configureEncoder: ((JSONEncoder) -> Void)? = nil,
         configureDecoder: ((JSONDecoder) -> Void)? = nil) {
        self.fileURL = fileURL
        self.strategy = decodeStrategy
        self.configureEncoder = configureEncoder
        self.configureDecoder = configureDecoder
        load()
    }

    // MARK: - Mutations (throwing)

    /// Apply `newItems` and persist; on failure the in-memory list is restored
    /// and the error rethrown, so memory never claims a state the disk lacks.
    private func commit(_ newItems: [Element]) throws {
        let previous = items
        items = newItems
        do { try save() } catch {
            items = previous
            throw error
        }
    }

    func tryAdd(_ element: Element) throws { try commit(items + [element]) }

    func tryUpdate(_ element: Element) throws {
        guard let index = items.firstIndex(where: { $0.id == element.id }) else { return }
        var next = items
        next[index] = element
        try commit(next)
    }

    func tryDelete(id: Element.ID) throws { try commit(items.filter { $0.id != id }) }

    func tryMove(draggedID: Element.ID, before targetID: Element.ID) throws {
        guard let next = reordered(draggedID: draggedID, before: targetID) else { return }
        try commit(next)
    }

    // MARK: - Mutations (non-throwing, failure recorded in `saveError`)

    func add(_ element: Element) { persistRecordingFailure { try tryAdd(element) } }

    func update(_ element: Element) { persistRecordingFailure { try tryUpdate(element) } }

    func delete(id: Element.ID) { persistRecordingFailure { try tryDelete(id: id) } }

    /// Reorder: move the element with `draggedID` to just before the element with
    /// `targetID`. If `targetID` is not found, nothing changes.
    /// Only the in-memory array order is changed here; callers that maintain a
    /// parallel `sortOrder` field must resequence it after this call.
    func move(draggedID: Element.ID, before targetID: Element.ID) {
        persistRecordingFailure { try tryMove(draggedID: draggedID, before: targetID) }
    }

    private func reordered(draggedID: Element.ID, before targetID: Element.ID) -> [Element]? {
        guard draggedID != targetID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
              items.contains(where: { $0.id == targetID }) else { return nil }
        var result = items
        let item = result.remove(at: fromIndex)
        let insertAt = result.firstIndex(where: { $0.id == targetID }) ?? result.endIndex
        result.insert(item, at: insertAt)
        return result
    }

    /// Runs a throwing mutation. A failure has already rolled memory back (see
    /// `commit`), so it is only recorded here, never left half-applied.
    private func persistRecordingFailure(_ mutation: () throws -> Void) {
        do {
            try mutation()
        } catch {
            saveError = error
            ClippyLog.error("JSON store save failed for \(fileURL.lastPathComponent): \(error)",
                            category: ClippyLog.storage)
        }
    }

    // MARK: - Load error resolution

    /// The user chose to carry on (typically with an empty list) after a load
    /// error. When the corrupt file could not be moved aside it is copied to a
    /// `.corrupt-` sibling first, and if even that fails this throws and saving
    /// stays refused: the unreadable file is never destroyed.
    func resolveLoadError() throws {
        guard let error = loadError else { return }
        if case .corrupt(_, nil) = error, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: siblingURL(tag: "corrupt"))
        }
        loadError = nil
        lastSyncedModification = modificationDate()
    }

    // MARK: - External writes

    /// Re-read the file when another process has written it since our last load
    /// or save. Returns true when a reload happened, so the owning store knows to
    /// republish. A redundant republish is cheap; a missed one leaves the UI
    /// showing a stale list, so this errs toward reloading.
    ///
    /// Without this the in-memory `items` array is authoritative and the next
    /// `save()` silently clobbers whatever the MCP server wrote. Scripts and AI
    /// actions are edited rarely and the file is a few KB, so a stat plus an
    /// occasional decode costs nothing.
    @discardableResult
    func reloadIfModifiedExternally() -> Bool {
        guard let modified = modificationDate(), modified != lastSyncedModification else {
            return false
        }
        load()
        return true
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    // MARK: - Persistence

    /// `<file>.<tag>-<ISO date>` next to the store file.
    private func siblingURL(tag: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(tag)-\(stamp)")
    }

    /// Element wrapper that turns a per-element decode failure into nil.
    private struct Lossy: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
    }

    private func load() {
        let decoder = JSONDecoder()
        configureDecoder?(decoder)
        lastSyncedModification = modificationDate()
        loadError = nil
        skippedElementCount = 0
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            return
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch {
            // Unreadable right now (permissions, mid-write): keep the file, refuse saves.
            items = []
            loadError = .corrupt(reason: error.localizedDescription, quarantinedTo: nil)
            return
        }
        do {
            switch strategy {
            case .strict:
                items = try decoder.decode([Element].self, from: data)
            case .lossy:
                let boxes = try decoder.decode([Lossy].self, from: data)
                items = boxes.compactMap(\.value)
                skippedElementCount = boxes.count - items.count
                if skippedElementCount > 0 {
                    // Keep the original: the next save would drop the bad entries.
                    try? data.write(to: siblingURL(tag: "lossy"), options: .atomic)
                }
            }
        } catch {
            items = []
            quarantine(reason: String(describing: error))
        }
    }

    /// Move the undecodable file aside, byte-for-byte, and record the error.
    private func quarantine(reason: String) {
        let target = siblingURL(tag: "corrupt")
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            lastSyncedModification = nil
            loadError = .corrupt(reason: reason, quarantinedTo: target)
            ClippyLog.error("JSON store \(fileURL.lastPathComponent) unreadable; preserved as \(target.lastPathComponent)",
                            category: ClippyLog.storage)
        } catch {
            loadError = .corrupt(reason: reason, quarantinedTo: nil)
        }
    }

    /// Encode and write atomically. Throws on a pending load error, an encode
    /// failure, or a write failure; on success clears `saveError`.
    func save() throws {
        if loadError != nil { throw JSONFileStoreError.unresolvedLoadError }
        let encoder = JSONEncoder()
        // Pretty-printing and sorted keys are always set so the on-disk format
        // is human-readable and stable for diffing. The wrapper adds extra
        // settings (e.g. .iso8601 date strategy) on top via configureEncoder.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        configureEncoder?(encoder)
        let data = try encoder.encode(items)
        try data.write(to: fileURL, options: .atomic)
        // Record our own write so reloadIfModifiedExternally does not mistake it
        // for somebody else's.
        lastSyncedModification = modificationDate()
        saveError = nil
    }
}
