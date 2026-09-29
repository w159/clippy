import Foundation

/// Case conversions (upper, lower, title, sentence, camel, snake, kebab, constant).
enum CaseTransforms {
    /// Every case transform.
    static let all: [any TextTransform] = [
        make("case.upper", "UPPERCASE") { $0.uppercased() },
        make("case.lower", "lowercase") { $0.lowercased() },
        make("case.title", "Title Case") { titleCase($0) },
        make("case.sentence", "Sentence case") { sentenceCase($0) },
        make("case.camel", "camelCase") { camelCase(words(in: $0)) },
        make("case.snake", "snake_case") { words(in: $0).map { $0.lowercased() }.joined(separator: "_") },
        make("case.kebab", "kebab-case") { words(in: $0).map { $0.lowercased() }.joined(separator: "-") },
        make("case.constant", "CONSTANT_CASE") { words(in: $0).map { $0.uppercased() }.joined(separator: "_") }
    ]

    private static func make(_ id: String, _ title: String, _ body: @escaping @Sendable (String) -> String) -> any TextTransform {
        FunctionTransform(id: id, title: title, category: .textCase, keywords: ["case"], body: body)
    }

    /// Splits on non-alphanumerics, lower-to-upper boundaries and acronym ends ("HTTPServer" -> HTTP, Server).
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current: [Character] = []
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            guard char.isLetter || char.isNumber else {
                if !current.isEmpty { result.append(String(current)); current = [] }
                continue
            }
            if let last = current.last, char.isUppercase {
                let nextIsLower = index + 1 < chars.count && chars[index + 1].isLowercase
                if last.isLowercase || last.isNumber || (last.isUppercase && nextIsLower) {
                    result.append(String(current)); current = []
                }
            }
            current.append(char)
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    private static func camelCase(_ parts: [String]) -> String {
        parts.enumerated().map { index, word in
            index == 0 ? word.lowercased() : word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined()
    }

    /// Capitalises the first letter of each word, lowercases the rest, keeps separators.
    private static func titleCase(_ text: String) -> String {
        var result = ""
        var atStart = true
        for char in text {
            if char.isLetter || char.isNumber {
                result += atStart ? char.uppercased() : char.lowercased()
                atStart = false
            } else {
                result.append(char)
                atStart = !(char == "'" || char == "\u{2019}")
            }
        }
        return result
    }

    /// Capitalises the first letter of each sentence, lowercases the rest.
    private static func sentenceCase(_ text: String) -> String {
        var result = ""
        var atStart = true
        for char in text {
            if char.isLetter {
                result += atStart ? char.uppercased() : char.lowercased()
                atStart = false
            } else {
                result.append(char)
                if char == "." || char == "!" || char == "?" || char == "\n" { atStart = true }
            }
        }
        return result
    }
}
