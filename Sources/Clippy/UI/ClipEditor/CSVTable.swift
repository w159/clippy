import Foundation

/// A parsed delimited table for the CSV preview (FEAT-14) and the language
/// sniffer. Pure: quote-aware (RFC 4180 style, `""` escapes, embedded
/// delimiters and newlines inside quotes), delimiter auto-detected.
struct CSVTable: Equatable {
    var rows: [[String]]
    var delimiter: Character
    /// Rows beyond `maxRows` were dropped from `rows`.
    var truncatedRows: Int

    static let maxRows = 200
    static let maxColumns = 30
    static let delimiters: [Character] = [",", "\t", ";", "|"]

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// Display width (characters) per column, capped so one long cell cannot
    /// push the rest off screen.
    func columnWidths(cap: Int = 40) -> [Int] {
        (0..<columnCount).map { column in
            min(cap, max(1, rows.compactMap { column < $0.count ? $0[column].count : nil }.max() ?? 1))
        }
    }

    /// Parses `text`, or returns nil when it does not look tabular: fewer than
    /// two rows, fewer than two columns, or a ragged row count.
    /// With `requireRectangular` false (the live preview, where a row is
    /// briefly short while typing) ragged rows are kept as they are.
    static func parse(_ text: String, maxRows: Int = CSVTable.maxRows, requireRectangular: Bool = true) -> CSVTable? {
        guard let delimiter = detectDelimiter(text, lenient: !requireRectangular) else { return nil }
        var rows = parseRows(text, delimiter: delimiter)
        while let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        guard rows.count >= 2 else { return nil }
        let width = rows[0].count
        guard width >= 2 else { return nil }
        if requireRectangular, !rows.allSatisfy({ $0.count == width }) { return nil }
        let dropped = max(0, rows.count - maxRows)
        let capped = rows.prefix(maxRows).map { Array($0.prefix(maxColumns)) }
        return CSVTable(rows: capped, delimiter: delimiter, truncatedRows: dropped)
    }

    /// Table for the live preview: only the first `previewCharacterLimit`
    /// characters (cut at a line boundary) are parsed, ragged rows allowed.
    static let previewCharacterLimit = 200_000

    static func preview(_ text: String) -> CSVTable? {
        var sample = text
        if text.count > previewCharacterLimit {
            sample = String(text.prefix(previewCharacterLimit))
            if let cut = sample.lastIndex(of: "\n") { sample = String(sample[..<cut]) }
        }
        return parse(sample, requireRectangular: false)
    }

    /// Characters of leading text examined for delimiter detection.
    private static let detectionLimit = 20_000

    /// The delimiter that splits the first (up to 20) rows into the same
    /// number (at least 2) of fields, or nil. `lenient` (the live preview)
    /// accepts a delimiter when the header has 2+ fields and at least half of
    /// the rows match it, so a half-typed row does not blank the preview.
    static func detectDelimiter(_ text: String, lenient: Bool = false) -> Character? {
        let truncated = text.count > detectionLimit
        let sample = truncated ? String(text.prefix(detectionLimit)) : text
        for delimiter in delimiters {
            var rows = parseRows(sample, delimiter: delimiter)
            if truncated, !rows.isEmpty { rows.removeLast() }   // possibly cut mid-row
            while let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
            let counts = rows.prefix(20).map(\.count)
            guard counts.count >= 2, let header = counts.first, header >= 2 else { continue }
            let matching = counts.filter { $0 == header }.count
            if matching == counts.count || (lenient && matching * 2 >= counts.count) { return delimiter }
        }
        return nil
    }

    /// Splits into rows of fields; a trailing newline yields no extra row.
    static func parseRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var pending = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 } else { inQuotes = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
                pending = true
            } else if character == delimiter {
                row.append(field); field = ""; pending = true
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); rows.append(row); row = []; field = ""; pending = false
            } else {
                field.append(character); pending = true
            }
            index += 1
        }
        if pending || !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
