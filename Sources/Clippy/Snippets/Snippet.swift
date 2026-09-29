import Foundation

/// One text snippet: an abbreviation that expands to a template body.
struct Snippet: Codable, Identifiable, Equatable {
    /// Stable identifier.
    var id: UUID
    /// Typed trigger, e.g. ";sig". Never empty for an enabled snippet.
    var abbreviation: String
    /// Display name.
    var title: String
    /// Template text with `{placeholders}` (see `SnippetTemplate`).
    var body: String
    /// Optional folder name used by the manager's filter.
    var folder: String
    /// Free-form tags.
    var tags: [String]
    /// Disabled snippets never expand but stay in the list.
    var isEnabled: Bool
    /// How many times the snippet was inserted or expanded.
    var useCount: Int
    /// Creation time.
    var createdAt: Date

    /// Creates a snippet.
    init(id: UUID = UUID(), abbreviation: String = "", title: String = "", body: String = "", folder: String = "",
         tags: [String] = [], isEnabled: Bool = true, useCount: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.abbreviation = abbreviation
        self.title = title
        self.body = body
        self.folder = folder
        self.tags = tags
        self.isEnabled = isEnabled
        self.useCount = useCount
        self.createdAt = createdAt
    }

    /// Tolerant decode: only `id` is required so older or hand-edited files keep loading.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        abbreviation = try box.decodeIfPresent(String.self, forKey: .abbreviation) ?? ""
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try box.decodeIfPresent(String.self, forKey: .body) ?? ""
        folder = try box.decodeIfPresent(String.self, forKey: .folder) ?? ""
        tags = try box.decodeIfPresent([String].self, forKey: .tags) ?? []
        isEnabled = try box.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        useCount = try box.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        createdAt = try box.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// Name shown in lists: the title, else the abbreviation, else "Untitled".
    var displayName: String {
        if !title.isEmpty { return title }
        return abbreviation.isEmpty ? "Untitled snippet" : abbreviation
    }
}
