import Foundation
import Combine

/// One finished run, as remembered by the history list. Output text lives in
/// memory only: script output can contain client data, so the optional
/// on-disk history carries metadata and never stdout or stderr.
struct ScriptRunRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var scriptID: UUID
    var startedAt: Date
    var outcome: ScriptResult.Outcome
    var exitCode: Int32
    var durationMs: Int
    /// Session-only. Excluded from `CodingKeys`, so never written to disk.
    var stdout: String? = nil
    var stderr: String? = nil

    enum CodingKeys: String, CodingKey { case id, scriptID, startedAt, outcome, exitCode, durationMs }

    /// Characters of each stream kept in memory per record.
    static let outputMemoryCap = 20_000
}

/// Persists the user's scripts as a JSON file. Decoupled from the clip database
/// since scripts are a small, separate concern. Injectable file URL for tests.
@MainActor
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()

    /// Runs remembered per script.
    static let historyLimit = 20
    /// UserDefaults key for the optional on-disk run history (metadata only).
    static let persistHistoryKey = "scripts.persistRunHistory"

    @Published private(set) var scripts: [Script] = []
    /// Newest first, at most `historyLimit` per script.
    @Published private(set) var history: [ScriptRunRecord] = []
    /// Set when entries were moved to a quarantine file; the Settings view
    /// shows it once so a bad entry never disappears silently.
    @Published var quarantineNotice: String?

    private let store: JSONFileStore<Script>
    /// Kept so add/update can verify the on-disk write actually landed (the
    /// generic JSONFileStore swallows encode/write errors with `try?`). Surfacing
    /// this lets the Settings editor show an error banner with Retry instead of
    /// silently dropping a save on a full disk or permission loss.
    private let fileURL: URL
    private let defaults: UserDefaults
    private var lastSanitizedModification: Date?

    /// When true the run history metadata is written next to scripts.json.
    var persistHistory: Bool {
        didSet {
            defaults.set(persistHistory, forKey: Self.persistHistoryKey)
            if persistHistory { saveHistory() } else { try? FileManager.default.removeItem(at: historyURL) }
        }
    }

    private var historyURL: URL { fileURL.deletingPathExtension().appendingPathExtension("history.json") }

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard, persistHistory: Bool? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.defaults = defaults
        self.persistHistory = persistHistory ?? defaults.bool(forKey: Self.persistHistoryKey)
        // Repair the file before the generic store reads it: a single bad entry
        // must not make it decode to nothing (and then get overwritten).
        var loadNotice: String?
        Self.sanitize(fileURL: url, notice: &loadNotice)
        quarantineNotice = loadNotice
        lastSanitizedModification = Self.modificationDate(of: url)
        store = JSONFileStore<Script>(
            fileURL: url,
            configureEncoder: { $0.dateEncodingStrategy = .iso8601 },
            configureDecoder: { $0.dateDecodingStrategy = .iso8601 }
        )
        // Migration: if all sortOrder values are 0 (first load after upgrade from a
        // build without sortOrder), backfill sequential values from the current
        // alphabetical order so the visible list does not jump.
        let loaded = store.items
        let allZero = loaded.allSatisfy { $0.sortOrder == 0 }
        if allZero && loaded.count > 1 {
            let alphabetical = loaded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let backfilled = alphabetical.enumerated().map { idx, script in
                var script = script; script.sortOrder = idx; return script
            }
            // Update through the store so it persists.
            for script in backfilled { store.update(script) }
            scripts = Self.ordered(store.items)
        } else {
            scripts = Self.ordered(loaded)
        }
        if self.persistHistory { loadHistory() }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scripts.json")
    }

    /// Stable order: `sortOrder`, then original position, so equal keys (all-zero
    /// legacy data, imports) never shuffle between reloads.
    static func ordered(_ items: [Script]) -> [Script] {
        items.enumerated()
            .sorted { $0.element.sortOrder != $1.element.sortOrder
                ? $0.element.sortOrder < $1.element.sortOrder
                : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Lossy load and quarantine (SCR-07)

    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Rewrites `fileURL` without entries that cannot be decoded, saving them to
    /// a sibling `scripts.quarantine-<stamp>.json`. A file that is not a JSON
    /// array at all is copied to quarantine whole and left for the generic store.
    static func sanitize(fileURL: URL, notice: inout String?) {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let fileManager = FileManager.default
        do {
            let decoded = try Script.decodeLossy(data)
            guard !decoded.rejected.isEmpty else { return }
            let name = writeQuarantine(decoded.rejected.map { chunk in
                (try? JSONSerialization.jsonObject(with: chunk, options: [.fragmentsAllowed])) ?? NSNull()
            }, beside: fileURL)
            if let encoded = try? Script.makeEncoder().encode(decoded.scripts) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
            let count = decoded.rejected.count
            notice = "\(count) script\(count == 1 ? "" : "s") could not be read and \(count == 1 ? "was" : "were") "
                + "moved to \(name ?? "a quarantine file")."
        } catch {
            let stamp = quarantineStamp()
            let dest = fileURL.deletingLastPathComponent()
                .appendingPathComponent("scripts.quarantine-\(stamp)-whole-file.json")
            if (try? fileManager.copyItem(at: fileURL, to: dest)) != nil {
                notice = "scripts.json was not valid and was copied to \(dest.lastPathComponent)."
            }
        }
    }

    private static func quarantineStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4))
    }

    /// Returns the quarantine file name, or nil if the write failed.
    private static func writeQuarantine(_ entries: [Any], beside fileURL: URL) -> String? {
        guard JSONSerialization.isValidJSONObject(entries),
              let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let dest = fileURL.deletingLastPathComponent()
            .appendingPathComponent("scripts.quarantine-\(quarantineStamp()).json")
        do { try data.write(to: dest, options: .atomic) } catch { return nil }
        return dest.lastPathComponent
    }

    // MARK: - CRUD

    /// Adds the script and returns whether the write persisted to disk. `false`
    /// means the JSON write failed (disk full, permissions, encode error); the
    /// caller should surface an error with a Retry. The in-memory list is still
    /// updated optimistically so the session is not left inconsistent.
    @discardableResult
    func add(_ script: Script) -> Bool {
        var edited = script
        edited.sortOrder = (scripts.map(\.sortOrder).max() ?? -1) + 1
        store.add(edited)
        scripts = Self.ordered(store.items)
        return persisted(contains: edited.id)
    }

    /// Updates the script and returns whether the write persisted to disk.
    @discardableResult
    func update(_ script: Script) -> Bool {
        guard scripts.contains(where: { $0.id == script.id }) else { return false }
        var updated = script
        updated.updatedAt = Date()
        store.update(updated)
        scripts = Self.ordered(store.items)
        return persisted(contains: updated.id)
    }

    func delete(id: UUID) {
        store.delete(id: id)
        scripts = Self.ordered(store.items)
        history.removeAll { $0.scriptID == id }
        if persistHistory { saveHistory() }
    }

    func script(id: UUID) -> Script? {
        scripts.first { $0.id == id }
    }

    /// Pick up scripts written by the MCP server process. Without this the
    /// in-memory list wins and the next save clobbers them. Driven by
    /// ExternalChangeWatcher; returns true when the list was republished.
    @discardableResult
    func reloadIfModifiedExternally() -> Bool {
        // Repair the file first if someone else touched it, so one bad entry
        // written by another process is quarantined instead of wiping the list.
        let modified = Self.modificationDate(of: fileURL)
        if modified != lastSanitizedModification {
            var notice: String?
            Self.sanitize(fileURL: fileURL, notice: &notice)
            if let notice { quarantineNotice = notice }
            lastSanitizedModification = Self.modificationDate(of: fileURL)
        }
        guard store.reloadIfModifiedExternally() else { return false }
        scripts = Self.ordered(store.items)
        return true
    }

    /// Re-reads the JSON file and confirms the given id round-tripped. This is a
    /// post-condition check on the just-completed write; scripts are tiny so the
    /// extra read is negligible. Returns false on any decode/IO failure so callers
    /// can surface a real error instead of assuming success.
    private func persisted(contains id: UUID) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Script.decodeLossy(data) else { return false }
        return decoded.scripts.contains { $0.id == id }
    }

    /// Reorder: move the script identified by `draggedID` to just before the
    /// script identified by `targetID`. Resequences all sortOrder values
    /// gap-free and persists.
    func moveScript(draggedID: UUID, before targetID: UUID) {
        store.move(draggedID: draggedID, before: targetID)
        // Resequence gap-free so sortOrder always reflects array position.
        // The generic store only reorders the array; sortOrder renumbering is
        // Script-specific and stays here.
        var reordered = store.items
        for index in reordered.indices { reordered[index].sortOrder = index }
        for script in reordered { store.update(script) }
        scripts = Self.ordered(store.items)
    }

    // MARK: - Duplicate, import, export, search (SCR-12)

    /// Copies a script right after the original. The copy is disabled: like an
    /// MCP-created script it must be reviewed before it can run. Returns nil
    /// when the id is unknown.
    @discardableResult
    func duplicate(id: UUID) -> Script? {
        guard let original = script(id: id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = original.name.isEmpty ? "Untitled copy" : original.name + " copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.isEnabled = false
        guard add(copy) else { return nil }
        // Place the copy directly below the original.
        if let idx = scripts.firstIndex(where: { $0.id == original.id }),
           idx + 1 < scripts.count, scripts[idx + 1].id != copy.id,
           let next = scripts.first(where: { $0.sortOrder > original.sortOrder && $0.id != copy.id }) {
            moveScript(draggedID: copy.id, before: next.id)
        }
        return self.script(id: copy.id)
    }

    /// Scripts as a JSON array for sharing. Run history is never included.
    func exportJSON(ids: Set<UUID>? = nil) throws -> Data {
        let chosen = scripts.filter { ids?.contains($0.id) ?? true }
        return try Script.makeEncoder().encode(chosen)
    }

    struct ImportResult: Equatable {
        var imported: Int
        var rejected: Int
    }

    /// Adds every readable script in `data` under a fresh id. Imported scripts
    /// arrive disabled, the same policy as scripts created over MCP: code that
    /// came from a file is reviewed before it can run. Bad entries are counted,
    /// not fatal. Throws when `data` is not a JSON array.
    @discardableResult
    func importJSON(_ data: Data) throws -> ImportResult {
        let decoded = try Script.decodeLossy(data)
        var imported = 0
        for var script in decoded.scripts {
            script.id = UUID()
            script.isEnabled = false
            script.createdAt = Date()
            script.updatedAt = Date()
            if add(script) { imported += 1 }
        }
        return ImportResult(imported: imported, rejected: decoded.rejected.count)
    }

    /// Scripts whose name or body contains `query` (case- and diacritic-
    /// insensitive). An empty query returns every script.
    func search(_ query: String) -> [Script] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scripts }
        return scripts.filter { Self.matches($0, query: trimmed) }
    }

    static func matches(_ script: Script, query: String) -> Bool {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return script.name.range(of: query, options: opts) != nil
            || script.body.range(of: query, options: opts) != nil
    }

    // MARK: - Run history

    /// Records a finished run and trims to `historyLimit` for that script.
    func recordRun(scriptID: UUID, startedAt: Date, result: ScriptResult) {
        var record = ScriptRunRecord(scriptID: scriptID, startedAt: startedAt, outcome: result.outcome,
                                     exitCode: result.exitCode, durationMs: result.durationMs)
        record.stdout = String(result.stdout.prefix(ScriptRunRecord.outputMemoryCap))
        record.stderr = String(result.stderr.prefix(ScriptRunRecord.outputMemoryCap))
        history.insert(record, at: 0)
        var kept = 0
        history = history.filter { entry in
            guard entry.scriptID == scriptID else { return true }
            kept += 1
            return kept <= Self.historyLimit
        }
        if persistHistory { saveHistory() }
    }

    func history(for scriptID: UUID) -> [ScriptRunRecord] {
        history.filter { $0.scriptID == scriptID }
    }

    func clearHistory(for scriptID: UUID) {
        history.removeAll { $0.scriptID == scriptID }
        if persistHistory { saveHistory() }
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    private func loadHistory() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? decoder.decode([ScriptRunRecord].self, from: data) else { return }
        history = decoded
    }
}
