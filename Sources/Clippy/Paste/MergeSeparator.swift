import Foundation

/// Separator choices for merge and append (FEAT-13). Raw values are persisted.
enum MergeSeparator: String, CaseIterable, Identifiable {
    case newline
    case blankLine
    case space
    case comma
    case tab

    var id: String { rawValue }

    /// Text inserted between merged parts.
    var text: String {
        switch self {
        case .newline: return "\n"
        case .blankLine: return "\n\n"
        case .space: return " "
        case .comma: return ", "
        case .tab: return "\t"
        }
    }

    /// Menu / picker label.
    var label: String {
        switch self {
        case .newline: return "New line"
        case .blankLine: return "Blank line"
        case .space: return "Space"
        case .comma: return "Comma"
        case .tab: return "Tab"
        }
    }
}
