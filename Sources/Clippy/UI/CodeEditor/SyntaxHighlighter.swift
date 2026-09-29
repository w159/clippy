import Foundation

/// Languages the code editor can highlight. `ScriptInterpreter` maps onto these
/// (see `ScriptInterpreter.codeLanguage`); the clip editor can pick `.json` or
/// `.plain` for its own content.
enum CodeLanguage: String, CaseIterable, Identifiable {
    case plain, shell, python, javascript, ruby, swift, applescript, json
    case markdown, sql, markup, csv

    var id: String { rawValue }

    /// Line comment prefix, used by comment-toggle and auto-indent decisions.
    var lineComment: String? {
        switch self {
        case .shell, .python, .ruby: return "#"
        case .javascript, .swift: return "//"
        case .applescript: return "--"
        case .sql: return "--"
        case .plain, .json, .markdown, .markup, .csv: return nil
        }
    }
}

/// The visual classes a token can take. Colors come from `CodeEditorTheme`.
enum CodeTokenKind: CaseIterable {
    case keyword, string, comment, number, type, function, variable, attribute, op
}

/// A highlighted span. `range` is in UTF-16 units, as NSTextStorage expects.
struct CodeToken: Equatable {
    var range: NSRange
    var kind: CodeTokenKind
}

/// Regex-grammar tokenizer. Each language is one alternation of rules compiled
/// once; scanning left to right means the earliest match wins and, at the same
/// start, the earlier rule wins. That gives strings and comments priority over
/// keywords inside them without any nesting logic. Pure and thread-safe.
enum SyntaxHighlighter {

    /// Text longer than this (UTF-16 units) is left unhighlighted to keep typing
    /// responsive.
    static let maxHighlightLength = 250_000

    static func tokens(in text: String, language: CodeLanguage) -> [CodeToken] {
        let nsText = text as NSString
        guard nsText.length > 0, nsText.length <= maxHighlightLength,
              let grammar = grammars[language] else { return [] }
        var result: [CodeToken] = []
        grammar.regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            for (index, kind) in grammar.kinds.enumerated() {
                let group = match.range(at: index + 1)
                if group.location != NSNotFound {
                    result.append(CodeToken(range: group, kind: kind))
                    return
                }
            }
        }
        return result
    }

    // MARK: Grammars

    private struct Grammar {
        let regex: NSRegularExpression
        let kinds: [CodeTokenKind]
    }

    private static let grammars: [CodeLanguage: Grammar] = {
        var table: [CodeLanguage: Grammar] = [:]
        for language in CodeLanguage.allCases {
            let rules = SyntaxHighlighter.rules(for: language)
            guard !rules.isEmpty else { continue }
            let pattern = rules.map { "(\($0.pattern))" }.joined(separator: "|")
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                table[language] = Grammar(regex: regex, kinds: rules.map(\.kind))
            } else {
                assertionFailure("Invalid grammar for \(language)")
            }
        }
        return table
    }()

    private static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    private static let cNumber = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
    private static let dqString = #""(?:[^"\\]|\\[\s\S])*""#
    private static let sqString = #"'(?:[^'\\]|\\[\s\S])*'"#
    private static let capitalized = #"\b[A-Z][A-Za-z0-9_]*\b"#

    private static func rules(for language: CodeLanguage) -> [(pattern: String, kind: CodeTokenKind)] {
        switch language {
        case .plain:
            return []
        case .shell:
            return [
                (#"(?<![^\s;&|(])#[^\n]*"#, .comment),
                (dqString, .string),
                (#"'[^']*'"#, .string),
                (#"\$(?:\{[^}\n]*\}|\([^)\n]*\)|[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?!$-])"#, .variable),
                (words(
                    "if then else elif fi for while until do done case esac in function select return exit break continue local " +
                    "export readonly declare typeset unset shift source alias time"
                ), .keyword),
                (words("echo printf cd pwd read eval exec test trap set true false cat grep sed awk pbcopy pbpaste open"), .function),
                (#"\b\d+\b"#, .number),
                (#"&&|\|\||[|;<>&]"#, .op),
            ]
        case .python:
            return [
                (#"#[^\n]*"#, .comment),
                (#"[rRbBuUfF]{0,2}(?:"{3}[\s\S]*?"{3}|'{3}[\s\S]*?'{3})"#, .string),
                (#"[rRbBuUfF]{0,2}"(?:[^"\\\n]|\\.)*""#, .string),
                (#"[rRbBuUfF]{0,2}'(?:[^'\\\n]|\\.)*'"#, .string),
                (#"@[A-Za-z_][\w.]*"#, .attribute),
                (words(
                    "and as assert async await break class continue def del elif else except finally for from global if import in " +
                    "is lambda nonlocal not or pass raise return try while with yield None True False self cls"
                ), .keyword),
                (words("print len range int str float list dict set tuple open input isinstance enumerate zip map filter sorted sum min max abs any all super type"), .function),
                (cNumber, .number),
                (capitalized, .type),
            ]
        case .javascript:
            return [
                (#"//[^\n]*"#, .comment),
                (#"/\*[\s\S]*?\*/"#, .comment),
                (#"`(?:[^`\\]|\\[\s\S])*`"#, .string),
                (dqString.replacingOccurrences(of: #"[\s\S]"#, with: "."), .string),
                (sqString.replacingOccurrences(of: #"[\s\S]"#, with: "."), .string),
                (words(
                    "async await break case catch class const continue debugger default delete do else export extends finally for " +
                    "from function if import in instanceof let new of return static super switch this throw try typeof var void " +
                    "while with yield null undefined true false"
                ), .keyword),
                (words("console require process module exports JSON Math Promise Object Array Date Buffer setTimeout setInterval fetch"), .function),
                (cNumber, .number),
                (capitalized, .type),
                (#"=>"#, .op),
            ]
        case .ruby:
            return [
                (#"(?m)^=begin\b[\s\S]*?^=end\b"#, .comment),
                (#"#[^\n]*"#, .comment),
                (dqString, .string),
                (sqString, .string),
                (#"%[qQwWiI]?\{[^}\n]*\}"#, .string),
                (#"@@?[A-Za-z_]\w*|\$[A-Za-z_]\w*"#, .variable),
                (#":[A-Za-z_]\w*[?!]?"#, .attribute),
                (words(
                    "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or " +
                    "redo rescue retry return self super then true undef unless until when while yield"
                ), .keyword),
                (words("puts print p require require_relative attr_accessor attr_reader attr_writer raise lambda proc"), .function),
                (cNumber, .number),
                (capitalized, .type),
            ]
        case .swift:
            return [
                (#"//[^\n]*"#, .comment),
                (#"/\*[\s\S]*?\*/"#, .comment),
                (#""{3}[\s\S]*?"{3}"#, .string),
                (dqString, .string),
                (#"[@#][A-Za-z_]\w*"#, .attribute),
                (words(
                    "actor any as associatedtype async await break case catch class continue default defer deinit do else enum " +
                    "extension fallthrough false fileprivate final for func guard if import in indirect init inout internal is " +
                    "lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self " +
                    "Self static struct subscript super switch throw throws true try typealias var weak where while"
                ), .keyword),
                (cNumber, .number),
                (capitalized, .type),
                (#"\b[a-z_]\w*(?=\()"#, .function),
            ]
        case .applescript:
            return appleScriptRules()
        case .json:
            return [
                (#""(?:[^"\\]|\\.)*"(?=\s*:)"#, .attribute),
                (dqString.replacingOccurrences(of: #"[\s\S]"#, with: "."), .string),
                (#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number),
                (#"\b(?:true|false|null)\b"#, .keyword),
            ]
        case .markdown, .sql, .markup, .csv:
            return SyntaxGrammars.rules(for: language)
        }
    }

    private static func appleScriptRules() -> [(pattern: String, kind: CodeTokenKind)] {
            return [
                (#"--[^\n]*|#[^\n]*"#, .comment),
                (#"\(\*[\s\S]*?\*\)"#, .comment),
                (#""(?:[^"\\]|\\.)*""#, .string),
                ("(?i:" + words(
                    "tell end if then else repeat with while times from to by in of set get return on error try considering " +
                    "ignoring using terms application whose is not and or contains exit given script property global local true " +
                    "false missing value"
                ) + ")", .keyword),
                ("(?i:" + words("display dialog notification alert activate delay do shell script open quit choose file folder keystroke key code the clipboard") + ")", .function),
                (#"\b\d+(?:\.\d+)?\b"#, .number),
            ]
    }
}

// MARK: - Line index

/// UTF-16 offsets of each line start, with binary-search lookup. Drives the
/// line-number gutter without rescanning the text on every draw.
struct LineIndex: Equatable {
    private(set) var starts: [Int]

    init(text: String) {
        var result = [0]
        let nsText = text as NSString
        var index = 0
        let length = nsText.length
        while index < length {
            let range = nsText.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(range)
            if next >= length {
                // A trailing newline starts one more (empty) line.
                if range.length > 0, nsText.character(at: length - 1) == 0x0A || nsText.character(at: length - 1) == 0x0D { result.append(length) }
                break
            }
            result.append(next)
            index = next
        }
        starts = result
    }

    var lineCount: Int { starts.count }

    /// Zero-based line containing UTF-16 `offset`.
    func line(containing offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// True when `offset` is exactly the first character of a line.
    func isLineStart(_ offset: Int) -> Bool {
        starts[line(containing: offset)] == offset
    }
}

// MARK: - Auto-indent

/// How one indent level is inserted by Tab and auto-indent.
enum CodeIndentUnit: Equatable {
    case spaces(Int)
    case tab

    var string: String {
        switch self {
        case .spaces(let width): return String(repeating: " ", count: max(1, width))
        case .tab: return "\t"
        }
    }
}

/// Pure rules for what Return inserts and how block indentation shifts.
enum CodeIndentation {

    /// Leading spaces and tabs of the line containing `offset`.
    static func leadingWhitespace(of text: NSString, at offset: Int) -> String {
        let line = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        var end = line.location
        while end < NSMaxRange(line), [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        return text.substring(with: NSRange(location: line.location, length: end - line.location))
    }

    /// What pressing Return at `cursor` should insert: a newline plus the
    /// current line's indent, one level deeper after an opener (`{`, `(`, `[`,
    /// a Python/Ruby `:`, shell `then`/`do`), and when the cursor sits between a
    /// bracket pair a further indented line plus a closing line.
    /// `caretOffset` is where the caret lands, counted from the insert start.
    static func newline(in text: String, cursor: Int, unit: CodeIndentUnit,
                        language: CodeLanguage) -> (insert: String, caretOffset: Int) {
        let nsText = text as NSString
        let cursor = min(max(0, cursor), nsText.length)
        let indent = leadingWhitespace(of: nsText, at: cursor)
        let lineStart = nsText.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = nsText.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
            .trimmingCharacters(in: .whitespaces)
        let after: Character? = cursor < nsText.length ? Character(UnicodeScalar(nsText.character(at: cursor)) ?? " ") : nil

        let opensBlock = before.last.map { "{([".contains($0) } ?? false
            || (language == .python && before.hasSuffix(":"))
            || (language == .ruby && (before.hasSuffix(" do") || before.hasPrefix("def ") || before.hasPrefix("if ")
                                      || before.hasPrefix("class ") || before.hasPrefix("while ")))
            || (language == .shell && (before.hasSuffix("then") || before.hasSuffix(" do") || before == "do"
                                       || before.hasSuffix("else")))
        guard opensBlock else {
            let text = "\n" + indent
            return (text, text.utf16.count)
        }
        let inner = "\n" + indent + unit.string
        if let closer = after, let opener = before.last, pairs[opener] == closer {
            let text = inner + "\n" + indent
            return (text, inner.utf16.count)
        }
        return (inner, inner.utf16.count)
    }

    static let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]

    /// `text` lines within `range` indented by one unit (`outdent == false`) or
    /// unindented by up to one unit. Returns the replacement for the full
    /// affected line range and the range it replaces.
    static func shiftLines(in text: String, range: NSRange, unit: CodeIndentUnit,
                           outdent: Bool) -> (replacement: String, replacedRange: NSRange) {
        let nsText = text as NSString
        var affected = nsText.lineRange(for: range)
        // A selection ending at the start of a line does not include that line.
        if range.length > 0, nsText.character(at: NSMaxRange(range) - 1) == 0x0A {
            affected = nsText.lineRange(for: NSRange(location: range.location, length: range.length - 1))
        }
        let block = nsText.substring(with: affected)
        let unitString = unit.string
        var lines = block.components(separatedBy: "\n")
        let trailingEmpty = lines.last == "" && lines.count > 1
        if trailingEmpty { lines.removeLast() }
        lines = lines.map { line in
            if !outdent { return line.isEmpty ? line : unitString + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var remaining = unitString.count
            var trimmed = Substring(line)
            while remaining > 0, trimmed.first == " " { trimmed = trimmed.dropFirst(); remaining -= 1 }
            return String(trimmed)
        }
        let joined = lines.joined(separator: "\n") + (trailingEmpty ? "\n" : "")
        return (joined, affected)
    }
}

// MARK: - Bracket matching

enum BracketMatcher {
    private static let open: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
    private static let close: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]

    /// For a caret at `offset`, the pair of bracket positions to highlight: the
    /// bracket just before the caret (preferred) or just after it, and its match.
    /// Depth counting ignores quotes; it is a visual aid, not a parser.
    static func pair(in text: NSString, caret offset: Int) -> (NSInteger, NSInteger)? {
        for candidate in [offset - 1, offset] where candidate >= 0 && candidate < text.length {
            let unit = text.character(at: candidate)
            if let closing = open[unit], let match = scan(text, from: candidate, step: 1, target: closing, same: unit) {
                return (candidate, match)
            }
            if let opening = close[unit], let match = scan(text, from: candidate, step: -1, target: opening, same: unit) {
                return (candidate, match)
            }
        }
        return nil
    }

    private static func scan(_ text: NSString, from start: Int, step: Int, target: unichar, same: unichar) -> Int? {
        var depth = 0
        var index = start
        while index >= 0, index < text.length {
            let unit = text.character(at: index)
            if unit == same { depth += 1 }
            else if unit == target { depth -= 1; if depth == 0 { return index } }
            index += step
        }
        return nil
    }
}
