import Foundation

/// Whitespace, quoting, escaping and markup clean-up transforms.
enum CleanupTransforms {
    /// Every clean-up transform.
    static let all: [any TextTransform] = [
        FunctionTransform(id: "cleanup.trim", title: "Trim whitespace", category: .cleanup) {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        },
        FunctionTransform(id: "cleanup.collapse", title: "Collapse whitespace", category: .cleanup,
                          keywords: ["spaces"]) { collapse($0) },
        FunctionTransform(id: "cleanup.quote", title: "Quote", category: .cleanup) { "\"" + escapeJSON($0) + "\"" },
        FunctionTransform(id: "cleanup.unquote", title: "Unquote", category: .cleanup) { try unquote($0) },
        FunctionTransform(id: "escape.json", title: "Escape (JSON)", category: .cleanup) { escapeJSON($0) },
        FunctionTransform(id: "unescape.json", title: "Unescape (JSON)", category: .cleanup) { try unescapeJSON($0) },
        FunctionTransform(id: "escape.shell", title: "Escape (shell)", category: .cleanup) { shellQuote($0) },
        FunctionTransform(id: "unescape.shell", title: "Unescape (shell)", category: .cleanup) { try shellUnquote($0) },
        FunctionTransform(id: "cleanup.striphtml", title: "Strip HTML tags", category: .cleanup) { stripHTML($0) }
    ]

    /// Trims and collapses every run of whitespace (including newlines) to a single space.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// JSON string-body escaping (no surrounding quotes).
    static func escapeJSON(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Reverses `escapeJSON`; accepts the standard JSON escapes and \\uXXXX (including surrogate pairs).
    static func unescapeJSON(_ text: String) throws -> String {
        guard text.contains("\\") else { return text }
        var fixed = "\""
        var escaped = false
        for char in text {
            if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { fixed += "\\" }
            fixed.append(char)
        }
        fixed += "\""
        guard let data = fixed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            throw TransformError.invalid("Contains an invalid escape sequence.")
        }
        return value
    }

    /// Removes one layer of matching double or single quotes.
    static func unquote(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "\"" || first == "'" else {
            throw TransformError.invalid("The text is not wrapped in matching quotes.")
        }
        let inner = String(trimmed.dropFirst().dropLast())
        return first == "\"" ? try unescapeJSON(inner) : inner.replacingOccurrences(of: "\\'", with: "'")
    }

    /// POSIX single-quote escaping.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Reverses `shellQuote` for the simple single-quoted form.
    static func shellUnquote(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") else {
            throw TransformError.invalid("The text is not a single-quoted shell string.")
        }
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Removes tags, script/style bodies and decodes common entities.
    static func stripHTML(_ text: String) -> String {
        var result = text
        for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?s)<!--.*?-->", "(?s)<[^>]*>"] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return EncodingTransforms.htmlDecode(result)
    }
}
