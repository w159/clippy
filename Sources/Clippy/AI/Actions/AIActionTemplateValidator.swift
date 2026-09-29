import Foundation

/// Checks an action's prompt template before it is saved or tested (AI-14).
/// Only `{clip}` and `{instruction}` are substituted; anything else in braces is
/// sent to the model literally, which is almost always a typo.
enum AIActionTemplateValidator {
    struct Issue: Equatable, Identifiable {
        enum Severity: Equatable { case error, warning }
        let severity: Severity
        let message: String
        var id: String { "\(severity)-\(message)" }
    }

    static let knownPlaceholders: [String] = ["clip", "instruction"]

    static func validate(_ template: String) -> [Issue] {
        var issues: [Issue] = []
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Issue(severity: .error, message: "The prompt template is empty.")]
        }
        let found = placeholders(in: template)
        for name in found where !knownPlaceholders.contains(name) {
            let hint = knownPlaceholders.first { $0.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            let suggestion = hint.map { " Did you mean {\($0)}?" } ?? ""
            issues.append(Issue(severity: .warning,
                                message: "{\(name)} is not a placeholder and will be sent as written.\(suggestion)"))
        }
        if !found.contains("clip") {
            issues.append(Issue(severity: .warning,
                                message: "The template has no {clip}, so the clip text will not be sent to the model."))
        }
        let opens = template.filter { $0 == "{" }.count
        let closes = template.filter { $0 == "}" }.count
        if opens != closes {
            issues.append(Issue(severity: .warning, message: "Braces are unbalanced ({ \(opens), } \(closes))."))
        }
        return issues
    }

    static func hasErrors(_ issues: [Issue]) -> Bool { issues.contains { $0.severity == .error } }

    /// Names inside `{...}` (letters, digits, underscore, spaces), in order, unique.
    static func placeholders(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{([A-Za-z_][A-Za-z0-9_ ]*)\\}") else { return [] }
        let nsTemplate = template as NSString
        var seen: [String] = []
        for match in regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length)) {
            let name = nsTemplate.substring(with: match.range(at: 1))
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}
