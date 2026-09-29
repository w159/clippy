import Foundation

/// Everything a template expansion may depend on. All impure inputs are injected.
struct SnippetContext {
    /// "Now" for `{date}` / `{time}`.
    var now: Date = Date()
    /// Calendar for date formatting.
    var calendar: Calendar = .current
    /// Locale for date formatting.
    var locale: Locale = .current
    /// Current clipboard text, supplied by the caller (never read from the pasteboard here).
    var clipboard: String = ""
    /// Values for `{fill:Label}` keyed by label; missing labels expand to "".
    var fillValues: [String: String] = [:]
    /// Source of `{uuid}`.
    var makeUUID: () -> UUID = { UUID() }
    /// Source of `{random:N}`; returns a value in `0...upper`.
    var randomInt: (Int) -> Int = { Int.random(in: 0...$0) }
    /// Whether `{env:NAME}` is honoured. Off by default.
    var allowEnvironment = false
    /// Environment used by `{env:NAME}`.
    var environment: [String: String] = ProcessInfo.processInfo.environment
}

/// Result of expanding a template.
struct SnippetExpansion: Equatable {
    /// The expanded text.
    let text: String
    /// Characters between the `{cursor}` marker and the end of `text`, or nil when there is no marker.
    let cursorOffsetFromEnd: Int?
    /// Ordered, de-duplicated `{fill:Label}` labels.
    let fields: [String]
}

/// Pure placeholder engine.
///
/// Placeholders: `{date}`, `{date:FORMAT}`, `{time}`, `{clipboard}`, `{cursor}`, `{fill:Label}`,
/// `{uuid}`, `{random:N}`, `{env:NAME}`. Unknown placeholders stay literal; `{{` and `}}` produce
/// literal braces.
enum SnippetTemplate {
    /// Largest `N` accepted by `{random:N}` digits.
    static let maxRandomDigits = 64

    /// Expands `template` using `context`.
    static func expand(_ template: String, context: SnippetContext = SnippetContext()) -> SnippetExpansion {
        var out = ""
        var cursorMarker: Int?
        var fields: [String] = []
        var index = template.startIndex
        while index < template.endIndex {
            let char = template[index]
            let next = template.index(after: index)
            if char == "{", next < template.endIndex, template[next] == "{" { out.append("{"); index = template.index(after: next); continue }
            if char == "}", next < template.endIndex, template[next] == "}" { out.append("}"); index = template.index(after: next); continue }
            guard char == "{", let close = template[next...].firstIndex(of: "}"),
                  !template[next..<close].contains("{") else { out.append(char); index = next; continue }
            let token = String(template[next..<close])
            if token == "cursor" {
                if cursorMarker == nil { cursorMarker = out.count }
                index = template.index(after: close)
            } else if let value = value(for: token, context: context, fields: &fields) {
                out += value
                index = template.index(after: close)
            } else {
                out.append(char)
                index = next
            }
        }
        let offset = cursorMarker.map { out.count - $0 }
        return SnippetExpansion(text: out, cursorOffsetFromEnd: offset, fields: fields)
    }

    /// The `{fill:Label}` labels in `template`, in order, without expanding anything.
    static func fillFields(in template: String) -> [String] {
        expand(template, context: SnippetContext(allowEnvironment: false)).fields
    }

    private static func value(for token: String, context: SnippetContext, fields: inout [String]) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        let argument = parts.count > 1 ? parts[1] : nil
        switch name {
        case "date": return format(context, argument ?? "yyyy-MM-dd")
        case "time": return argument == nil ? format(context, "HH:mm") : nil
        case "clipboard": return argument == nil ? context.clipboard : nil
        case "uuid": return argument == nil ? context.makeUUID().uuidString : nil
        case "random": return randomDigits(argument, context)
        case "env": return environmentValue(argument, context)
        case "fill":
            guard let label = argument, !label.isEmpty else { return nil }
            if !fields.contains(label) { fields.append(label) }
            return context.fillValues[label] ?? ""
        default: return nil
        }
    }

    private static func format(_ context: SnippetContext, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.locale = context.locale
        formatter.dateFormat = pattern
        return formatter.string(from: context.now)
    }

    private static func randomDigits(_ argument: String?, _ context: SnippetContext) -> String? {
        guard let argument, let count = Int(argument), (1...maxRandomDigits).contains(count) else { return nil }
        return (0..<count).map { _ in String(context.randomInt(9)) }.joined()
    }

    private static func environmentValue(_ argument: String?, _ context: SnippetContext) -> String? {
        guard let argument, !argument.isEmpty else { return nil }
        return context.allowEnvironment ? (context.environment[argument] ?? "") : nil
    }
}
