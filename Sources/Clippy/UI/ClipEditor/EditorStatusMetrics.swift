import Foundation

/// Pure counters behind the editor status bar (EDT-06): caret line/column in
/// grapheme units, plus the character counts the footer and VoiceOver report.
struct EditorStatusSnapshot: Equatable {
    /// 1-based caret line.
    let line: Int
    /// 1-based caret column, counted in grapheme clusters from the line start.
    let column: Int
    /// Grapheme clusters selected (0 for a bare caret).
    let selectedCharacters: Int
    /// Total grapheme clusters (what the user perceives as characters).
    let characters: Int
    /// Total UTF-16 code units (NSString length; what NSRange uses).
    let utf16Units: Int
    /// Total lines (0 for empty text, matching the footer's line count).
    let lines: Int

    /// "Ln 3, Col 15", with the selection appended when one exists.
    var caretLabel: String {
        selectedCharacters > 0 ? "Ln \(line), Col \(column) (\(selectedCharacters) selected)" : "Ln \(line), Col \(column)"
    }

    /// "182 chars" / "1 char".
    var characterLabel: String { "\(characters) \(characters == 1 ? "char" : "chars")" }

    /// Spoken form for the whole bar.
    var spokenLabel: String {
        "Line \(line), column \(column), \(characters) \(characters == 1 ? "character" : "characters")"
            + (selectedCharacters > 0 ? ", \(selectedCharacters) selected" : "")
    }
}

/// Computes `EditorStatusSnapshot` values from text and a UTF-16 selection.
enum EditorStatusMetrics {
    /// Snapshot for `text` with `selection` expressed as an NSRange (UTF-16).
    /// Out-of-range selections are clamped; a range that splits a surrogate
    /// pair or grapheme rounds down to the enclosing boundary.
    static func snapshot(text: String, selection: NSRange) -> EditorStatusSnapshot {
        let utf16Total = text.utf16.count
        let location = min(max(0, selection.location), utf16Total)
        let end = min(max(location, location + max(0, selection.length)), utf16Total)
        let caret = index(in: text, utf16Offset: location)
        let selectionEnd = index(in: text, utf16Offset: end)

        var line = 1
        var column = 1
        for character in text[..<caret] {
            if character.isNewline {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        let selected = text[caret..<max(caret, selectionEnd)].count
        return EditorStatusSnapshot(
            line: line, column: column, selectedCharacters: selected, characters: text.count,
            utf16Units: utf16Total, lines: lineCount(text))
    }

    /// Lines as the footer counts them: 0 when empty, else newline count + 1.
    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// A valid Character-boundary index at (or just before) the UTF-16 offset.
    private static func index(in text: String, utf16Offset: Int) -> String.Index {
        var probe = String.Index(utf16Offset: utf16Offset, in: text)
        // `samePosition(in:)` is nil off a Character boundary; step back to the enclosing one.
        while probe > text.startIndex, probe.samePosition(in: text) == nil {
            probe = text.utf16.index(before: probe)
        }
        return probe
    }
}
