import Foundation

/// Picks the highlighting grammar for a clip's text (EDT-06). A light content
/// sniffer, not a parser: JSON must actually parse, everything else is scored
/// from line-level signals and needs a score of at least 2 to win, so ordinary
/// prose stays `.plain`.
enum EditorLanguageSniffer {
    /// Only this many leading characters are examined.
    static let window = 8192

    private struct Signal {
        let regex: NSRegularExpression?
        let weight: Int
        /// A pattern that fails to compile is a programmer error in the static
        /// table above; it degrades to a signal that never matches.
        init(_ pattern: String, _ weight: Int = 1, options: NSRegularExpression.Options = [.anchorsMatchLines]) {
            regex = try? NSRegularExpression(pattern: pattern, options: options)
            self.weight = weight
        }
    }

    private static let scored: [(language: CodeLanguage, signals: [Signal])] = [
        (.swift, [
            Signal(#"^\s*import (?:Foundation|SwiftUI|AppKit|UIKit|Combine|XCTest)\b"#, 2),
            Signal(#"^\s*(?:@main|@MainActor|@State|@Published|@Observable)\b"#, 2),
            Signal(#"^\s*(?:(?:public|private|internal|fileprivate|final|static|override|open)\s+)*(?:func|struct|class|enum|extension|protocol|actor)\s+\w+"#, 1),
            Signal(#"^\s*guard\b.+\belse\b"#, 2),
            Signal(#"^\s*(?:let|var)\s+\w+\s*(?::\s*[\w\[\]<>?]+)?\s*="#, 1),
            Signal(#"\bif let \w+"#, 1),
        ]),
        (.python, [
            Signal(#"^\s*def \w+\(.*\)\s*(?:->\s*[^:]+)?:\s*$"#, 2),
            Signal(#"^\s*(?:from [\w.]+ import [\w*, ]+|import [\w.]+(?: as \w+)?)\s*$"#, 2),
            Signal(#"^\s*class \w+(?:\(.*\))?:\s*$"#, 2),
            Signal(#"^\s*(?:if|elif|else|for|while|try|except|with)\b.*:\s*$"#, 1),
            Signal(#"^if __name__ == ['"]__main__['"]:"#, 2),
            Signal(#"\bself\.\w+"#, 1),
            Signal(#"\bprint\(.*\)\s*$"#, 1),
        ]),
        (.sql, [
            Signal(#"^\s*select\b[\s\S]*?\bfrom\b"#, 2, options: [.anchorsMatchLines, .caseInsensitive]),
            Signal(#"^\s*insert\s+into\s+\w+"#, 2, options: [.anchorsMatchLines, .caseInsensitive]),
            Signal(#"^\s*update\s+\w+\s+set\b"#, 2, options: [.anchorsMatchLines, .caseInsensitive]),
            Signal(#"^\s*delete\s+from\s+\w+"#, 2, options: [.anchorsMatchLines, .caseInsensitive]),
            Signal(#"^\s*(?:create|alter|drop)\s+(?:table|index|view|database|schema)\b"#, 2,
                   options: [.anchorsMatchLines, .caseInsensitive]),
            Signal(#"\b(?:where|group by|order by|inner join|left join)\b"#, 1, options: [.caseInsensitive]),
        ]),
        (.shell, [
            Signal(#"^\s*(?:sudo|brew|apt(?:-get)?|npm|npx|pip3?|yarn|git|docker|kubectl|curl|wget|chmod|chown|mkdir|"#
                   + #"export|source|cd|ls|cat|grep|sed|awk|ssh|scp|rm|mv|cp|echo|defaults|osascript)\s+\S"#, 2),
            Signal(#"^\s*\$ \S"#, 2),
            Signal(#"^\s*(?:if \[\[? .+\]\]?; then|fi|done|esac)\s*$"#, 2),
            Signal(#"^\s*[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s*$"#, 1),
            Signal(#"\s(?:&&|\|\|)\s|\s\|\s\w+"#, 1),
            Signal(#"\$\{?[A-Za-z_]\w*\}?"#, 1),
        ]),
        (.markdown, [
            Signal(#"^#{1,6} \S"#, 2),
            Signal(#"^\s{0,3}(?:`{3}|~{3})"#, 2),
            Signal(#"\[[^\]\n]+\]\((?:https?://|/|#|\.)[^)\n]*\)"#, 1),
            Signal(#"^\s*(?:[-*+]|\d+\.) \S"#, 1),
            Signal(#"^>\s?\S"#, 1),
            Signal(#"\*\*[^*\n]+\*\*"#, 1),
            Signal(#"^\|.+\|\s*$"#, 1),
        ]),
    ]

    /// Language for `text`; `.plain` when nothing clearly matches.
    static func detect(_ text: String) -> CodeLanguage {
        let sample = String(text.prefix(window)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return .plain }
        if isJSON(text, sample: sample) { return .json }
        if isMarkup(sample) { return .markup }
        if let shebang = shebangLanguage(sample) { return shebang }
        var best: (CodeLanguage, Int)?
        for entry in scored {
            let range = NSRange(location: 0, length: (sample as NSString).length)
            let score = entry.signals.reduce(0) { total, signal in
                total + (signal.regex?.firstMatch(in: sample, range: range) == nil ? 0 : signal.weight)
            }
            if score >= 2, score > (best?.1 ?? 0) { best = (entry.language, score) }
        }
        if let best { return best.0 }
        if CSVTable.parse(sample, maxRows: 20) != nil { return .csv }
        return .plain
    }

    /// The grammar for a stored clip's text: single-value kinds detected by
    /// `ClipKind` (color, link, email, path) are never highlighted; everything
    /// else is sniffed.
    static func language(forText text: String) -> CodeLanguage {
        switch ClipKind.detect(text) {
        case .colorValue, .link, .email, .filePath: return .plain
        case .file, .image, .text: return detect(text)
        }
    }

    // MARK: Signals

    private static func isJSON(_ text: String, sample: String) -> Bool {
        guard let first = sample.first, first == "{" || first == "[" else { return false }
        // Whole document when it is a reasonable size; a real parse is the only
        // reliable discriminator from code that merely starts with a bracket.
        if text.utf8.count <= 2_000_000,
           let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return true
        }
        // Truncated or slightly malformed (mid-edit) JSON: object-ish start with a key/value pair.
        return sample.range(of: #"^[{\[]\s*"[^"\n]+"\s*:"#, options: .regularExpression) != nil
    }

    private static func isMarkup(_ sample: String) -> Bool {
        let lower = sample.lowercased()
        if lower.hasPrefix("<?xml") || lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return true }
        guard lower.hasPrefix("<"), lower.hasSuffix(">") else { return false }
        // `<tag ...>` start and a closing/self-closing `>` end, with a tag pair or self-close inside.
        return lower.range(of: #"^<([a-z][\w:.-]*)(\s[^<>]*)?(/>|>[\s\S]*</\1\s*>)$"#,
                           options: .regularExpression) != nil
            || lower.range(of: #"^(?:<[a-z!/][^>]*>\s*){2,}$"#, options: .regularExpression) != nil
    }

    private static func shebangLanguage(_ sample: String) -> CodeLanguage? {
        guard sample.hasPrefix("#!") else { return nil }
        let line = sample.prefix { $0 != "\n" }.lowercased()
        if line.contains("python") { return .python }
        if line.contains("ruby") { return .ruby }
        if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
        if line.contains("osascript") { return .applescript }
        if line.contains("swift") { return .swift }
        return .shell
    }
}
