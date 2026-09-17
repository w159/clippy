import Foundation

/// A generic, file-backed JSON store for an ordered list of Codable + Identifiable values.
///
/// Responsibilities:
///   - Load from / save to a single JSON file atomically.
///   - Expose add / update / delete / move operations that persist after every mutation.
///   - Forward encoder/decoder configuration to the caller so date strategies,
///     custom keys, etc. live in the wrapper, not here.
///
/// Non-responsibilities (stay in the wrapper):
///   - sortOrder renumbering (requires knowledge of the element's fields).
///   - Migration (one-time data fixups belong to the store that owns the schema).
///   - Seeding (default-data logic is application-level, not persistence-level).
final class JSONFileStore<Element: Codable & Identifiable> {

    // MARK: - State

    private(set) var items: [Element] = []

    private let fileURL: URL
    private let configureEncoder: ((JSONEncoder) -> Void)?
    private let configureDecoder: ((JSONDecoder) -> Void)?

    /// Modification date of the file as of our last load or save. Anything newer
    /// was written by somebody else - in practice the MCP server process. See
    /// `reloadIfModifiedExternally`.
    private var lastSyncedModification: Date?

    // MARK: - Init

    init(fileURL: URL,
         configureEncoder: ((JSONEncoder) -> Void)? = nil,
         configureDecoder: ((JSONDecoder) -> Void)? = nil) {
        self.fileURL = fileURL
        self.configureEncoder = configureEncoder
        self.configureDecoder = configureDecoder
        load()
    }

    // MARK: - Mutations

    func add(_ element: Element) {
        items.append(element)
        save()
    }

    func update(_ element: Element) {
        guard let index = items.firstIndex(where: { $0.id == element.id }) else { return }
        items[index] = element
        save()
    }

    func delete(id: Element.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Reorder: move the element with `draggedID` to just before the element with
    /// `targetID`. If `targetID` is not found, the dragged element is appended.
    /// Only the in-memory array order is changed here; callers that maintain a
    /// parallel `sortOrder` field must resequence it after this call.
    func move(draggedID: Element.ID, before targetID: Element.ID) {
        guard draggedID != targetID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
              items.contains(where: { $0.id == targetID }) else { return }
        var reordered = items
        let item = reordered.remove(at: fromIndex)
        let insertAt = reordered.firstIndex(where: { $0.id == targetID }) ?? reordered.endIndex
        reordered.insert(item, at: insertAt)
        items = reordered
        save()
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

    private func load() {
        let decoder = JSONDecoder()
        configureDecoder?(decoder)
        lastSyncedModification = modificationDate()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Element].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        // Pretty-printing and sorted keys are always set so the on-disk format
        // is human-readable and stable for diffing. The wrapper adds extra
        // settings (e.g. .iso8601 date strategy) on top via configureEncoder.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        configureEncoder?(encoder)
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Record our own write so reloadIfModifiedExternally does not mistake it
        // for somebody else's.
        lastSyncedModification = modificationDate()
    }
}
