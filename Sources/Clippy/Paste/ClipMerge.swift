import Foundation

/// Merge and append operations over clips (CAP-08).
enum ClipMerge {
    /// The text of `clips` joined with `separator`, in order. Image and file
    /// clips and blank text are skipped. Nil when nothing remains.
    static func mergedText(_ clips: [Clip], separator: String = "\n") -> String? {
        let parts = clips.filter { $0.contentKind == .text && $0.contentText.contains { !$0.isWhitespace } }
            .map(\.contentText)
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// Saves the merge of `clips` as a new text clip and returns its id, or nil
    /// when there was nothing to merge. The originals are left untouched.
    @discardableResult
    static func saveMerged(_ clips: [Clip], separator: String = "\n", into database: ClipDatabase) throws -> Int64? {
        guard let text = mergedText(clips, separator: separator) else { return nil }
        return try database.insertTextClip(text, sourceAppName: "Clippy Merge")
    }

    /// Appends `addition` to the text clip `clip` (edits it in place, dropping
    /// its rich flavors since they no longer match). Returns false for a clip
    /// without a row id or a non-text clip.
    @discardableResult
    static func append(_ addition: String, to clip: Clip, separator: String = "\n", in database: ClipDatabase) throws -> Bool {
        guard clip.contentKind == .text, let id = clip.id, addition.contains(where: { !$0.isWhitespace }) else { return false }
        try database.updateClipText(id: id, newText: clip.contentText + separator + addition)
        return true
    }
}
