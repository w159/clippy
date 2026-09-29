import Foundation

/// Rule tables for the grammars the clip editor adds on top of the script
/// languages: Markdown, SQL, HTML/XML and CSV. Each rule is an
/// (ICU pattern, token kind) pair; `SyntaxHighlighter` compiles a language's
/// rules into one alternation where the earliest match wins and, at the same
/// start, the earlier rule wins. Pure data, no state.
enum SyntaxGrammars {
    typealias Rule = (pattern: String, kind: CodeTokenKind)

    static func rules(for language: CodeLanguage) -> [Rule] {
        switch language {
        case .markdown: return markdown
        case .sql: return sql
        case .markup: return markup
        case .csv: return csv
        default: return []
        }
    }

    private static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    /// Fenced code and HTML comments first (they may contain anything), then
    /// line-oriented block markers, then inline spans.
    static let markdown: [Rule] = [
        (#"(?m)^[ ]{0,3}(?:`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^[ ]{0,3}(?:`{3,}|~{3,})[ \t]*$|\z)"#, .string),
        (#"<!--[\s\S]*?-->"#, .comment),
        (#"(?m)^#{1,6}[ \t].*$"#, .keyword),
        (#"(?m)^(?:={2,}|-{2,})[ \t]*$"#, .keyword),
        (#"(?m)^[ \t]*>.*$"#, .comment),
        (#"(?m)^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#, .op),
        (#"`[^`\n]+`"#, .string),
        (#"!?\[[^\]\n]*\]\([^)\n]*\)"#, .function),
        (#"<https?://[^>\s]+>"#, .function),
        (#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type),
        (#"(?<![*\w])\*[^*\s][^*\n]*\*(?![*\w])|(?<![_\w])_[^_\s][^_\n]*_(?![_\w])"#, .variable),
    ]

    static let sql: [Rule] = [
        (#"--[^\n]*"#, .comment),
        (#"/\*[\s\S]*?\*/"#, .comment),
        (#"'(?:[^']|'')*'"#, .string),
        (#""[^"\n]*"|`[^`\n]*`|\[[^\]\n]*\]"#, .variable),
        ("(?i:" + words(
            "select from where and or not in is null like between exists distinct group " +
            "by order having limit offset join inner left right full outer cross on as " +
            "union all intersect except insert into values update set delete create alter drop table " +
            "index view database schema primary key foreign references unique default check constraint add column " +
            "truncate begin commit rollback transaction with recursive case when then else end asc desc " +
            "using returning"
        ) + ")", .keyword),
        ("(?i:" + words(
            "count sum avg min max coalesce ifnull nullif cast concat substr substring length lower " +
            "upper trim replace round abs now date datetime strftime extract row_number rank over partition"
        ) + ")", .function),
        ("(?i:" + words("int integer bigint smallint text varchar char boolean bool real float double decimal numeric date timestamp timestamptz blob json jsonb uuid serial") + ")", .type),
        (#"\b\d+(?:\.\d+)?\b"#, .number),
        (#"<>|!=|<=|>=|[=<>+\-*/%|]"#, .op),
    ]

    /// Comments, CDATA, doctype/processing instructions, tags, attribute
    /// names, quoted attribute values (only right after `=`, so prose quotes
    /// stay plain) and entities.
    static let markup: [Rule] = [
        (#"<!--[\s\S]*?-->"#, .comment),
        (#"<!\[CDATA\[[\s\S]*?\]\]>"#, .string),
        (#"<[?!][^>]*>"#, .attribute),
        (#"</?[A-Za-z][\w:.-]*"#, .keyword),
        (#"/?>"#, .keyword),
        (#"(?<==)[ \t]*(?:"[^"]*"|'[^']*')"#, .string),
        (#"[A-Za-z_:][\w:.-]*(?=[ \t]*=)"#, .attribute),
        (#"&(?:[A-Za-z][A-Za-z0-9]*|#\d+|#[xX][0-9a-fA-F]+);"#, .variable),
    ]

    /// The header row, quoted fields, numbers and delimiters.
    static let csv: [Rule] = [
        (#"\A[^\n]*"#, .keyword),
        (#""(?:[^"]|"")*""#, .string),
        (#"(?<![\w.])-?\d+(?:\.\d+)?(?![\w.])"#, .number),
        (#"[,;\t|]"#, .op),
    ]
}
