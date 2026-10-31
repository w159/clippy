import Foundation

/// What committing the inline rename field should do to a clip's title.
/// Shared by the card and row rename fields so they cannot drift apart.
enum RenameOutcome: Equatable {
    /// Text is what the field was seeded with: leave the clip alone.
    case unchanged
    /// Drop the custom title and fall back to the source app name.
    case clear
    /// Store this trimmed text as the custom title.
    case set(String)

    /// `seeded` is the exact text the field started with. It can be the
    /// "Unknown app" placeholder from `displayTitle`, which must never be
    /// persisted as a user title just because the user pressed Return.
    static func resolve(input: String, seeded: String, sourceAppName: String?) -> RenameOutcome {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == seeded.trimmingCharacters(in: .whitespacesAndNewlines) { return .unchanged }
        if trimmed.isEmpty || trimmed == sourceAppName { return .clear }
        return .set(trimmed)
    }
}
