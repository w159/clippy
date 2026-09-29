import Foundation

/// Word-level diff for action proposals (AI-10). Longest-common-subsequence over
/// whitespace-delimited tokens; whitespace is kept as its own tokens so the
/// reassembled text is exact.
enum AIWordDiff {
    enum Kind: Equatable { case same, removed, added }

    struct Span: Equatable {
        let kind: Kind
        let text: String
    }

    /// Tokens above this product size fall back to a whole-text replace: the LCS
    /// table is O(n*m) and a huge clip must not stall the main thread.
    static let maxCells = 4_000_000

    static func diff(old: String, new: String) -> [Span] {
        if old == new { return old.isEmpty ? [] : [Span(kind: .same, text: old)] }
        let oldTokens = tokenize(old), newTokens = tokenize(new)
        guard oldTokens.count * newTokens.count <= maxCells else {
            return [Span(kind: .removed, text: old), Span(kind: .added, text: new)].filter { !$0.text.isEmpty }
        }
        // lcs[row][col] = LCS length of oldTokens[row...] and newTokens[col...]
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: newTokens.count + 1), count: oldTokens.count + 1)
        for row in stride(from: oldTokens.count - 1, through: 0, by: -1) {
            for col in stride(from: newTokens.count - 1, through: 0, by: -1) {
                lcs[row][col] = oldTokens[row] == newTokens[col]
                    ? lcs[row + 1][col + 1] + 1 : max(lcs[row + 1][col], lcs[row][col + 1])
            }
        }
        var spans: [Span] = []
        func push(_ kind: Kind, _ text: String) {
            if let last = spans.last, last.kind == kind {
                spans[spans.count - 1] = Span(kind: kind, text: last.text + text)
            } else {
                spans.append(Span(kind: kind, text: text))
            }
        }
        var oldIndex = 0, newIndex = 0
        while oldIndex < oldTokens.count || newIndex < newTokens.count {
            if oldIndex < oldTokens.count, newIndex < newTokens.count,
               oldTokens[oldIndex] == newTokens[newIndex] {
                push(.same, oldTokens[oldIndex]); oldIndex += 1; newIndex += 1
            } else if oldIndex < oldTokens.count,
                      newIndex == newTokens.count || lcs[oldIndex + 1][newIndex] >= lcs[oldIndex][newIndex + 1] {
                // Ties prefer the removal so a replaced word reads "old" then "new".
                push(.removed, oldTokens[oldIndex]); oldIndex += 1
            } else {
                push(.added, newTokens[newIndex]); newIndex += 1
            }
        }
        return spans
    }

    /// Split into alternating runs of whitespace and non-whitespace.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if isSpace != currentIsSpace, !current.isEmpty {
                tokens.append(current); current = ""
            }
            current.append(character)
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
