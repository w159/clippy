import Foundation
import Combine

// MARK: - Model

/// What the engine does with the text the model produces.
enum AIActionOutputDisposition: String, Codable, CaseIterable, Identifiable {
    /// Offer the result as an edit to the source clip (shows before/after diff).
    case proposeEdit
    /// Save the result as a brand-new clip.
    case newClip
    /// Copy the result to the system clipboard silently.
    case copyToClipboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proposeEdit:      return "Propose Edit"
        case .newClip:          return "New Clip"
        case .copyToClipboard:  return "Copy to Clipboard"
        }
    }
}

/// A user-definable AI action. Prompt templates may contain:
///   {clip}        — the full text of the source clip
///   {instruction} — an extra instruction the UI can supply at run time
///
/// Built-in defaults are shipped via `AIActionStore.seedDefaults()`.
struct AIAction: Identifiable, Equatable {
    var id: UUID
    var name: String
    /// How the icon is represented: SF Symbol, emoji, or app bundle ID.
    /// Defaults to `.symbol` so the synthesized memberwise init stays
    /// source-compatible with existing call sites that predate the icon-kind field.
    var iconKind: CategoryIconKind = .symbol
    /// The icon value: SF Symbol name, emoji character, or app bundle ID.
    /// Named `symbolName` for JSON compatibility with older saved actions.
    var symbolName: String
    /// System-prompt template. Use `{clip}` and `{instruction}` as placeholders.
    var promptTemplate: String
    var temperature: Double
    var maxTokens: Int
    var outputDisposition: AIActionOutputDisposition
    /// Built-in actions may not be deleted, only edited.
    var isBuiltIn: Bool
    /// User-defined display order. Lower values appear first. Defaults to 0 so
    /// JSON saved by older builds (which have no sortOrder key) migrates cleanly
    /// via `decodeIfPresent ?? 0`. Test call sites that omit sortOrder continue
    /// to compile because of this default.
    var sortOrder: Int = 0
}

// MARK: - Codable with migration

extension AIAction: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, iconKind, symbolName, promptTemplate
        case temperature, maxTokens, outputDisposition, isBuiltIn, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decode(String.self, forKey: .symbolName)
        // Old JSON has no `iconKind`; default to .symbol so existing actions
        // that stored an SF Symbol name in `symbolName` continue to render correctly.
        iconKind = try c.decodeIfPresent(CategoryIconKind.self, forKey: .iconKind) ?? .symbol
        promptTemplate = try c.decode(String.self, forKey: .promptTemplate)
        temperature = try c.decode(Double.self, forKey: .temperature)
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        outputDisposition = try c.decode(AIActionOutputDisposition.self, forKey: .outputDisposition)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        // Old JSON has no sortOrder; default to 0 so migration backfill runs in load().
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(iconKind, forKey: .iconKind)
        try c.encode(symbolName, forKey: .symbolName)
        try c.encode(promptTemplate, forKey: .promptTemplate)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(outputDisposition, forKey: .outputDisposition)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
        try c.encode(sortOrder, forKey: .sortOrder)
    }
}

// MARK: - Template rendering

extension AIAction {
    /// True when the prompt template references `{instruction}`, meaning the UI
    /// must collect an instruction from the user before running. Built-ins like
    /// Rewrite, Translate, Change Tone, and Generate Clip would otherwise render
    /// the placeholder to an empty string and send the model a broken prompt.
    var needsInstruction: Bool { promptTemplate.contains("{instruction}") }

    /// Stable id of the built-in "Suggest Category" action. The UI routes this
    /// one through `AIService.suggestCategory` (which yields a `.category`
    /// proposal that files the clip) instead of the generic `run` path, whose
    /// `.proposeEdit` disposition would otherwise overwrite the clip body.
    static let suggestCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000008")!

    /// True when this is the built-in Suggest Category action.
    var isSuggestCategory: Bool { isBuiltIn && id == Self.suggestCategoryID }

    /// Substitute `{clip}` and `{instruction}`, then trim whitespace.
    func buildPrompt(clip: String, instruction: String = "") -> String {
        promptTemplate
            .replacingOccurrences(of: "{clip}", with: clip)
            .replacingOccurrences(of: "{instruction}", with: instruction)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Built-in defaults

extension AIAction {
    /// The seed set shipped with Clippy. Stored under stable UUIDs so they
    /// survive re-seeding without creating duplicates.
    static let builtIns: [AIAction] = [
        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
                 name: "Suggest Title",
                 iconKind: .symbol, symbolName: "textformat.size",
                 promptTemplate: "Write a short, descriptive title (3 to 6 words) for this clipboard snippet. Reply with only the title.\n\n{clip}",
                 temperature: 0.2, maxTokens: 32,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 0),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
                 name: "Rewrite",
                 iconKind: .symbol, symbolName: "pencil",
                 promptTemplate: "Rewrite the following text exactly as instructed. Reply with only the rewritten text.\n\nInstruction: {instruction}\n\nText:\n{clip}",
                 temperature: 0.4, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 1),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
                 name: "Summarize",
                 iconKind: .symbol, symbolName: "text.alignleft",
                 promptTemplate: "Summarize the following text in one or two plain sentences. Reply with only the summary.\n\n{clip}",
                 temperature: 0.3, maxTokens: 256,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 2),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!,
                 name: "Translate",
                 iconKind: .symbol, symbolName: "globe",
                 promptTemplate: "Translate the following text to {instruction}. Reply with only the translated text.\n\n{clip}",
                 temperature: 0.3, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 3),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!,
                 name: "Extract Key Points",
                 iconKind: .symbol, symbolName: "list.bullet",
                 promptTemplate: "Extract the key points from the following text as a short bulleted list. Reply with only the bullet points.\n\n{clip}",
                 temperature: 0.3, maxTokens: 512,
                 outputDisposition: .newClip, isBuiltIn: true, sortOrder: 4),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!,
                 name: "Change Tone",
                 iconKind: .symbol, symbolName: "waveform",
                 promptTemplate: "Rewrite the following text in a {instruction} tone. Reply with only the rewritten text.\n\n{clip}",
                 temperature: 0.5, maxTokens: 2048,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 5),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000007")!,
                 name: "Generate Clip",
                 iconKind: .symbol, symbolName: "sparkles",
                 promptTemplate: "Generate a single useful clipboard snippet based on this request. Reply with only the snippet text.\n\nRequest: {instruction}\n\nContext:\n{clip}",
                 temperature: 0.6, maxTokens: 1024,
                 outputDisposition: .newClip, isBuiltIn: true, sortOrder: 6),

        AIAction(id: UUID(uuidString: "A1000000-0000-0000-0000-000000000008")!,
                 name: "Suggest Category",
                 iconKind: .symbol, symbolName: "folder",
                 promptTemplate: "Assign this item to exactly one category from the provided list. Reply with only the category name. If none fit, reply NONE.\n\nCategories:\n{instruction}\n\nItem:\n{clip}",
                 temperature: 0.0, maxTokens: 24,
                 outputDisposition: .proposeEdit, isBuiltIn: true, sortOrder: 7),
    ]
}

// MARK: - Store

/// Persists user-defined and built-in AI actions as a JSON file, following the
/// same pattern as ScriptStore. Injectable `fileURL` for tests.
final class AIActionStore: ObservableObject {
    static let shared = AIActionStore()

    @Published private(set) var actions: [AIAction] = []

    private let store: JSONFileStore<AIAction>

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        // AIAction has no Date fields, so no date strategy is needed.
        store = JSONFileStore<AIAction>(fileURL: url)
        actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
        seedDefaults()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-actions.json")
    }

    // MARK: - Seeding

    /// Insert built-ins that are not yet present. Safe to call on every launch
    /// because it checks by stable id, not by index.
    func seedDefaults() {
        var changed = false
        for builtIn in AIAction.builtIns {
            if !actions.contains(where: { $0.id == builtIn.id }) {
                // Append after the current last entry to preserve user order.
                var seeded = builtIn
                seeded.sortOrder = (actions.map(\.sortOrder).max() ?? -1) + 1
                store.add(seeded)
                actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
                changed = true
            }
        }
        // store.add already saves after each insertion; no extra save needed.
        _ = changed
    }

    // MARK: - CRUD

    func add(_ action: AIAction) {
        var a = action
        a.sortOrder = (actions.map(\.sortOrder).max() ?? -1) + 1
        store.add(a)
        actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func update(_ action: AIAction) {
        guard actions.contains(where: { $0.id == action.id }) else { return }
        store.update(action)
        actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func delete(id: UUID) {
        // Built-ins may not be deleted.
        guard let target = actions.first(where: { $0.id == id }), !target.isBuiltIn else { return }
        store.delete(id: id)
        actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func action(id: UUID) -> AIAction? {
        actions.first { $0.id == id }
    }

    /// Pick up actions written by the MCP server process. Without this the
    /// in-memory list wins and the next save clobbers them. Driven by
    /// ExternalChangeWatcher; returns true when the list was republished.
    @discardableResult
    func reloadIfModifiedExternally() -> Bool {
        guard store.reloadIfModifiedExternally() else { return false }
        actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
        return true
    }

    /// Reorder: move the action identified by `draggedID` to just before the
    /// action identified by `targetID`. Built-ins are reorderable (only deletion
    /// is restricted). Resequences all sortOrder values gap-free and persists.
    func moveAction(draggedID: UUID, before targetID: UUID) {
        store.move(draggedID: draggedID, before: targetID)
        // Resequence gap-free so sortOrder always reflects array position.
        // The generic store only reorders the array; sortOrder renumbering is
        // AIAction-specific and stays here.
        var reordered = store.items
        for i in reordered.indices { reordered[i].sortOrder = i }
        for a in reordered { store.update(a) }
        actions = store.items.sorted { $0.sortOrder < $1.sortOrder }
    }
}
