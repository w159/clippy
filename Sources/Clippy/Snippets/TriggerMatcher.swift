import Foundation

/// How a typed abbreviation is committed.
enum SnippetTriggerMode: String, CaseIterable, Codable {
    /// Expand the moment the abbreviation is complete.
    case immediate
    /// Expand when a space, return or tab follows the abbreviation.
    case onDelimiter
}

/// Pure rolling-buffer matcher for typed abbreviations. No event or pasteboard access.
struct TriggerMatcher {
    /// A successful match.
    struct Match: Equatable {
        /// The matched snippet.
        let snippet: Snippet
        /// Characters to delete before inserting: the abbreviation, plus the delimiter when one was typed.
        let deleteCount: Int
        /// The delimiter that committed the match (nil in immediate mode).
        let delimiter: Character?
    }

    /// Maximum characters remembered.
    static let bufferLimit = 64
    /// Characters that commit an abbreviation in `.onDelimiter` mode.
    static let delimiters: Set<Character> = [" ", "\n", "\r", "\t"]

    /// Snippets considered for matching (disabled or empty-abbreviation ones are ignored).
    var snippets: [Snippet]
    /// Commit rule.
    var mode: SnippetTriggerMode
    /// Whether "SIG" differs from "sig".
    var caseSensitive: Bool
    private(set) var buffer: [Character] = []

    /// Creates a matcher.
    init(snippets: [Snippet] = [], mode: SnippetTriggerMode = .onDelimiter, caseSensitive: Bool = true) {
        self.snippets = snippets
        self.mode = mode
        self.caseSensitive = caseSensitive
    }

    /// Forgets everything typed so far (call on non-typing keys, focus changes, secure input).
    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    /// Removes the last typed character (Backspace).
    mutating func deleteBackward() { _ = buffer.popLast() }

    /// Feeds one typed character; returns a match when it completes a trigger. A match clears the buffer.
    mutating func feed(_ character: Character) -> Match? {
        if mode == .onDelimiter, Self.delimiters.contains(character) {
            let found = longestMatch(endingAt: buffer.count).map {
                Match(snippet: $0, deleteCount: $0.abbreviation.count + 1, delimiter: character)
            }
            if found != nil { reset() } else { append(character) }
            return found
        }
        append(character)
        guard mode == .immediate, let snippet = longestMatch(endingAt: buffer.count) else { return nil }
        reset()
        return Match(snippet: snippet, deleteCount: snippet.abbreviation.count, delimiter: nil)
    }

    private mutating func append(_ character: Character) {
        buffer.append(character)
        if buffer.count > Self.bufferLimit { buffer.removeFirst(buffer.count - Self.bufferLimit) }
    }

    /// Longest enabled abbreviation that is a suffix of `buffer[..<end]`; in delimiter mode it must also
    /// start at a word boundary (buffer start or after a delimiter).
    private func longestMatch(endingAt end: Int) -> Snippet? {
        var best: Snippet?
        for snippet in snippets where snippet.isEnabled && !snippet.abbreviation.isEmpty {
            let chars = Array(snippet.abbreviation)
            guard chars.count <= end else { continue }
            let start = end - chars.count
            if mode == .onDelimiter, start > 0, !Self.delimiters.contains(buffer[start - 1]) { continue }
            let slice = buffer[start..<end]
            let equal = caseSensitive ? Array(slice) == chars
                : String(slice).lowercased() == snippet.abbreviation.lowercased()
            if equal, best == nil || chars.count > best!.abbreviation.count { best = snippet }
        }
        return best
    }
}
