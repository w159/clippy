import AppIntents
import Foundation
import GRDB

/// A clip exposed to Shortcuts and Spotlight. Sensitive clips are never turned
/// into entities; the preview is capped and never includes secrets.
struct ClipEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Clip")
    static let defaultQuery = ClipEntityQuery()

    /// String form of the clip's database id (`Int64` is not a valid entity identifier).
    let id: String
    /// The database id.
    let clipID: Int64
    @Property(title: "Title") var title: String
    @Property(title: "Preview") var preview: String
    @Property(title: "Kind") var kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind)")
    }

    /// Builds an entity, or nil for sensitive/unsaved clips.
    init?(clip: Clip) {
        guard let identifier = clip.id, !SensitiveContent.isSensitive(clip: clip) else { return nil }
        id = String(identifier)
        clipID = identifier
        title = IntentQueryMapper.title(for: clip)
        preview = clip.contentKind == .text ? String(clip.previewText.prefix(200)) : ""
        kind = clip.contentKind.rawValue
    }
}

/// Looks clips up by id, suggestion, or the search grammar.
struct ClipEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ClipEntity] {
        let keys = identifiers.compactMap { Int64($0) }
        let clips: [Clip] = try await ClipDatabase.shared.dbQueue.read { try Clip.fetchAll($0, keys: keys) }
        return clips.compactMap(ClipEntity.init(clip:))
    }

    func entities(matching string: String) async throws -> [ClipEntity] {
        let query = IntentQueryMapper.grammarQuery(from: string)
        let clips = try ClipDatabase.shared.searchClips(matching: query, limit: IntentQueryMapper.maxResults * 2)
        return Array(clips.compactMap(ClipEntity.init(clip:)).prefix(IntentQueryMapper.maxResults))
    }

    func suggestedEntities() async throws -> [ClipEntity] {
        let clips = try ClipDatabase.shared.recentClips(limit: IntentQueryMapper.maxResults * 2)
        return Array(clips.compactMap(ClipEntity.init(clip:)).prefix(IntentQueryMapper.maxResults))
    }
}
