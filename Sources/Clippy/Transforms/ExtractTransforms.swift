import Foundation

/// Extraction and counting transforms.
enum ExtractTransforms {
    /// Every extraction transform.
    static let all: [any TextTransform] = [
        FunctionTransform(id: "extract.urls", title: "Extract URLs", category: .extract) {
            extract($0, pattern: "https?://[^\\s<>\"'\\)\\]]+")
        },
        FunctionTransform(id: "extract.emails", title: "Extract email addresses", category: .extract) {
            extract($0, pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}")
        },
        FunctionTransform(id: "extract.numbers", title: "Extract numbers", category: .extract) {
            extract($0, pattern: "[-+]?[0-9]+(?:[.,][0-9]+)*")
        },
        FunctionTransform(id: "count.stats", title: "Count words, characters, lines", category: .extract,
                          keywords: ["length", "statistics"]) { count($0) }
    ]

    /// Every regex match, one per line, duplicates removed in order.
    static func extract(_ text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let source = text as NSString
        var seen = Set<String>()
        var found: [String] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let range = match?.range else { return }
            let value = source.substring(with: range)
            if seen.insert(value).inserted { found.append(value) }
            if found.count >= 10_000 { stop.pointee = true }
        }
        return found.joined(separator: "\n")
    }

    /// "Words: N, Characters: N, Lines: N".
    static func count(_ text: String) -> String {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let lines = LineTransforms.split(text).count
        return "Words: \(words), Characters: \(text.count), Lines: \(lines)"
    }
}
