import Foundation

/// One lexical unit of a search query (see the grammar in ClipSearchQuery.swift).
struct QueryToken: Equatable {
    enum Body: Equatable {
        /// A bare word.
        case word(String)
        /// A `"quoted phrase"`; `terminated` is false when the closing quote is missing.
        case phrase(String, terminated: Bool)
        /// A legacy `#token` (text after the `#`, not lowercased).
        case hash(String)
        /// A `name:value` operator (name lowercased, value unquoted).
        case op(name: String, value: String)
    }

    /// True when the token carried a leading `-`.
    var negated: Bool
    var body: Body
    /// The token exactly as typed (used to rebuild queries around filter chips).
    var source: String
}

/// Splits a raw query string into `QueryToken`s. Pure and total: malformed input
/// (unterminated quotes, stray dashes, empty operator values) never throws.
enum QueryTokenizer {
    /// Operator names recognised before a `:`. Anything else (`https://x`) is a word.
    static let operatorNames: Set<String> = ["kind", "app", "in", "before", "after", "on", "size"]

    static func tokens(in raw: String) -> [QueryToken] {
        let chars = Array(raw)
        var out: [QueryToken] = []
        var pos = 0
        while pos < chars.count {
            if chars[pos].isWhitespace { pos += 1; continue }
            let start = pos
            var negated = false
            if chars[pos] == "-" {
                // A lone dash is noise; a leading dash on a token negates it.
                guard pos + 1 < chars.count, !chars[pos + 1].isWhitespace else { pos += 1; continue }
                negated = true
                pos += 1
            }
            let body: QueryToken.Body
            if chars[pos] == "\"" {
                let quoted = readQuoted(chars, from: pos)
                pos = quoted.next
                body = .phrase(quoted.text, terminated: quoted.terminated)
            } else if chars[pos] == "#" {
                let run = readRun(chars, from: pos + 1)
                pos = run.next
                body = run.text.isEmpty ? .word("#") : .hash(run.text)
            } else {
                let scanned = scanWord(chars, from: pos)
                pos = scanned.next
                body = scanned.body
            }
            out.append(QueryToken(negated: negated, body: body, source: String(chars[start..<pos])))
        }
        return out
    }

    /// Reads up to the next whitespace; `\x` yields a literal `x`.
    private static func readRun(_ chars: [Character], from start: Int) -> (text: String, next: Int) {
        var pos = start
        var text = ""
        while pos < chars.count, !chars[pos].isWhitespace {
            if chars[pos] == "\\", pos + 1 < chars.count {
                text.append(chars[pos + 1])
                pos += 2
            } else {
                text.append(chars[pos])
                pos += 1
            }
        }
        return (text, pos)
    }

    /// Reads a `"..."` span starting at the opening quote. `\"` and `\\` are escapes.
    private static func readQuoted(_ chars: [Character], from start: Int)
        -> (text: String, next: Int, terminated: Bool)
    {
        var pos = start + 1
        var text = ""
        while pos < chars.count {
            let character = chars[pos]
            if character == "\\", pos + 1 < chars.count, chars[pos + 1] == "\"" || chars[pos + 1] == "\\" {
                text.append(chars[pos + 1])
                pos += 2
            } else if character == "\"" {
                return (text, pos + 1, true)
            } else {
                text.append(character)
                pos += 1
            }
        }
        return (text, pos, false)
    }

    /// Scans a bare word, detecting a leading `operator:` prefix.
    private static func scanWord(_ chars: [Character], from start: Int) -> (body: QueryToken.Body, next: Int) {
        var pos = start
        var buffer = ""
        var sawEscape = false
        while pos < chars.count, !chars[pos].isWhitespace {
            let character = chars[pos]
            if character == "\\", pos + 1 < chars.count {
                buffer.append(chars[pos + 1])
                sawEscape = true
                pos += 2
                continue
            }
            if character == ":", !sawEscape, operatorNames.contains(buffer.lowercased()) {
                let name = buffer.lowercased()
                pos += 1
                if pos < chars.count, chars[pos] == "\"" {
                    let quoted = readQuoted(chars, from: pos)
                    return (.op(name: name, value: quoted.text), quoted.next)
                }
                let run = readRun(chars, from: pos)
                return (.op(name: name, value: run.text), run.next)
            }
            buffer.append(character)
            pos += 1
        }
        return (.word(buffer), pos)
    }
}
