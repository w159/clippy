import Foundation

/// Line-oriented transforms: sort, dedupe, reverse, number.
enum LineTransforms {
    /// Every line transform.
    static let all: [any TextTransform] = [
        FunctionTransform(id: "lines.sort.asc", title: "Sort lines A-Z", category: .lines) { sort($0, mode: .ascending) },
        FunctionTransform(id: "lines.sort.desc", title: "Sort lines Z-A", category: .lines) { sort($0, mode: .descending) },
        FunctionTransform(id: "lines.sort.numeric", title: "Sort lines numerically", category: .lines) {
            sort($0, mode: .numeric)
        },
        FunctionTransform(id: "lines.sort.ci", title: "Sort lines (case-insensitive)", category: .lines) {
            sort($0, mode: .caseInsensitive)
        },
        FunctionTransform(id: "lines.dedupe", title: "Remove duplicate lines", category: .lines, keywords: ["unique"]) { dedupe($0) },
        FunctionTransform(id: "lines.reverse", title: "Reverse lines", category: .lines) {
            split($0).reversed().joined(separator: "\n")
        },
        FunctionTransform(id: "lines.number", title: "Number lines", category: .lines) { number($0) }
    ]

    /// Ordering for `sort`.
    enum SortMode { case ascending, descending, numeric, caseInsensitive }

    /// Splits on any newline convention; a trailing newline does not create an empty last line.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Sorts lines; numeric puts non-numeric lines last in their original order.
    static func sort(_ text: String, mode: SortMode) -> String {
        let lines = split(text)
        let sorted: [String]
        switch mode {
        case .ascending: sorted = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .descending: sorted = lines.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        case .caseInsensitive: sorted = lines.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        case .numeric:
            let keyed = lines.enumerated().map { (index: $0.offset, line: $0.element, value: leadingNumber($0.element)) }
            sorted = keyed.sorted { lhs, rhs in
                switch (lhs.value, rhs.value) {
                case let (left?, right?): return left == right ? lhs.index < rhs.index : left < right
                case (nil, nil): return lhs.index < rhs.index
                case (_?, nil): return true
                case (nil, _?): return false
                }
            }.map(\.line)
        }
        return sorted.joined(separator: "\n")
    }

    private static func leadingNumber(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) { return value }
        guard let range = trimmed.range(of: "^[-+]?[0-9]*\\.?[0-9]+", options: .regularExpression) else { return nil }
        return Double(trimmed[range])
    }

    /// Removes repeated lines, keeping the first occurrence and the original order.
    static func dedupe(_ text: String) -> String {
        var seen = Set<String>()
        return split(text).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    /// Prefixes each line with a right-aligned 1-based number.
    static func number(_ text: String) -> String {
        let lines = split(text)
        let width = String(lines.count).count
        return lines.enumerated().map { index, line in
            String(repeating: " ", count: width - String(index + 1).count) + "\(index + 1). " + line
        }.joined(separator: "\n")
    }
}
