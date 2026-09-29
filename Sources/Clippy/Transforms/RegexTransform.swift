import Foundation

/// Regex find/replace with capture groups (`$1`) and hard safety caps.
struct RegexReplaceTransform: TextTransform {
    /// Limits applied to every run.
    enum Limits {
        static let maxPatternLength = 500
        static let maxInputBytes = 1_000_000
        static let maxMatches = 10_000
        static let maxSeconds: TimeInterval = 1.0
    }

    let id = "regex.replace"
    let title = "Regex replace"
    let category = TransformCategory.regex
    let keywords = ["find", "replace", "regular expression"]
    /// The ICU pattern.
    let pattern: String
    /// Replacement template; `$1` refers to capture group 1, `\$` is a literal dollar.
    let template: String
    /// Case-insensitive matching.
    let ignoreCase: Bool
    /// Wall-clock budget; overridable so tests can exercise the deadline.
    let maxSeconds: TimeInterval

    /// Creates a regex replacement.
    init(pattern: String, template: String, ignoreCase: Bool = false, maxSeconds: TimeInterval = Limits.maxSeconds) {
        self.pattern = pattern
        self.template = template
        self.ignoreCase = ignoreCase
        self.maxSeconds = maxSeconds
    }

    func transform(_ input: String) throws -> String {
        guard !pattern.isEmpty else { throw TransformError.unsafePattern(reason: "The pattern is empty.") }
        guard pattern.count <= Limits.maxPatternLength else {
            throw TransformError.unsafePattern(reason: "The pattern is longer than \(Limits.maxPatternLength) characters.")
        }
        guard input.utf8.count <= Limits.maxInputBytes else {
            throw TransformError.unsafePattern(reason: "The text is too large for regex replace.")
        }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw TransformError.unsafePattern(reason: "Invalid pattern: \(error.localizedDescription)")
        }
        let source = input as NSString
        let deadline = Date().addingTimeInterval(maxSeconds)
        var matches: [NSTextCheckingResult] = []
        var failure: String?
        regex.enumerateMatches(in: input, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Date() > deadline { failure = "The pattern took too long and was stopped."; stop.pointee = true; return }
            guard let match else { return }
            matches.append(match)
            if matches.count > Limits.maxMatches { failure = "Too many matches (over \(Limits.maxMatches))."; stop.pointee = true }
        }
        if let failure { throw TransformError.unsafePattern(reason: failure) }
        var out = ""
        var cursor = 0
        for match in matches {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += regex.replacementString(for: match, in: input, offset: 0, template: template)
            cursor = match.range.location + match.range.length
        }
        return out + source.substring(from: cursor)
    }
}
