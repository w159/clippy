import AppIntents
import AppKit
import Foundation

/// App hooks the integrator sets at launch (paste needs the live `PasteService`).
enum IntentHooks {
    /// Pastes `clip` into the frontmost app; returns false when it could not.
    nonisolated(unsafe) static var paste: (Clip) -> Bool = { _ in false }
}

/// Failures surfaced to Shortcuts.
enum ClippyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case empty, tooLarge, unavailable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: return "Nothing to add."
        case .tooLarge: return "That text is too large to add from a shortcut."
        case .unavailable(let what): return "\(what)"
        }
    }
}

struct SearchClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clips"
    static let description = IntentDescription("Finds clips using Clippy's search syntax. Sensitive clips are never returned.")

    @Parameter(title: "Query") var query: String
    @Parameter(title: "Limit", default: 10) var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> {
        let text = IntentQueryMapper.grammarQuery(from: query)
        let cap = IntentQueryMapper.clampedLimit(limit)
        let clips = try ClipDatabase.shared.searchClips(matching: text, limit: cap * 2)
        return .result(value: Array(clips.compactMap(ClipEntity.init(clip:)).prefix(cap)))
    }
}

struct GetLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Clip"
    static let description = IntentDescription("Returns the newest non-sensitive clip.")

    func perform() async throws -> some IntentResult & ReturnsValue<ClipEntity?> {
        let clips = try ClipDatabase.shared.recentClips(limit: 50)
        return .result(value: clips.lazy.compactMap(ClipEntity.init(clip:)).first)
    }
}

struct AddClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Clip"
    static let description = IntentDescription("Saves text as a new clip in Clippy.")

    @Parameter(title: "Text") var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<ClipEntity?> {
        guard !text.isEmpty else { throw ClippyIntentError.empty }
        guard text.utf8.count <= ClippyURL.maxTextBytes else { throw ClippyIntentError.tooLarge }
        try await requestConfirmation(result: .result(dialog: "Add \(text.utf8.count) bytes of text to Clippy?"))
        let identifier = try ClipDatabase.shared.insertTextClip(text, sourceAppName: "Shortcuts")
        AuditLog.shared.record(actor: "intent", action: "add", detail: "bytes=\(text.utf8.count)", clipIDs: [identifier])
        let clip = try? await ClipDatabase.shared.dbQueue.read { try Clip.fetchOne($0, key: identifier) }
        return .result(value: clip.flatMap(ClipEntity.init(clip:)))
    }
}

struct PasteClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste Clip"
    static let description = IntentDescription("Pastes a clip into the frontmost app.")

    @Parameter(title: "Clip") var clip: ClipEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let stored = try? await ClipDatabase.shared.dbQueue.read({ try Clip.fetchOne($0, key: clip.clipID) }),
              !SensitiveContent.isSensitive(clip: stored) else { throw ClippyIntentError.unavailable("Clip is unavailable.") }
        guard IntentHooks.paste(stored) else { throw ClippyIntentError.unavailable("Clippy could not paste (Accessibility?).") }
        AuditLog.shared.record(actor: "intent", action: "paste", detail: "ok", clipIDs: [clip.clipID])
        return .result()
    }
}

/// An enabled script offered to Shortcuts.
struct ScriptEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Script")
    static let defaultQuery = ScriptEntityQuery()
    let id: UUID
    @Property(title: "Name") var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ScriptEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ScriptEntity] {
        await MainActor.run { enabled().filter { identifiers.contains($0.id) } }
    }
    func suggestedEntities() async throws -> [ScriptEntity] { await MainActor.run { enabled() } }
    @MainActor private func enabled() -> [ScriptEntity] {
        ScriptStore.shared.scripts.filter(\.isEnabled).map { entity in
            let item = ScriptEntity(id: entity.id)
            item.name = entity.name
            return item
        }
    }
}

struct RunScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Script"
    static let description = IntentDescription("Runs an enabled Clippy script, honoring its sandbox setting.")

    @Parameter(title: "Script") var script: ScriptEntity
    @Parameter(title: "Input") var input: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stored = ScriptStore.shared.script(id: script.id), stored.isEnabled else {
            throw ClippyIntentError.unavailable("Script is disabled or missing.")
        }
        try await requestConfirmation(result: .result(dialog: "Run script \"\(stored.name)\"?"))
        let result = await ScriptRunner.run(stored, input: input, sandbox: ScriptSandboxPolicy().sandbox(for: stored.id))
        return .result(value: result.stdout)
    }
}

struct ClippyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchClipsIntent(), phrases: ["Search \(.applicationName) clips"],
                    shortTitle: "Search Clips", systemImageName: "magnifyingglass")
        AppShortcut(intent: GetLatestClipIntent(), phrases: ["Get latest \(.applicationName) clip"],
                    shortTitle: "Latest Clip", systemImageName: "clock")
        AppShortcut(intent: AddClipIntent(), phrases: ["Add to \(.applicationName)"],
                    shortTitle: "Add Clip", systemImageName: "plus")
    }
}
