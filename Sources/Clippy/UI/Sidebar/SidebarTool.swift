import SwiftUI

/// The fixed navigation destinations in the Tools group, shared by the
/// expanded list and the icon rail so both reach the same set.
enum SidebarTool: CaseIterable, Hashable {
    case onePassword, scripts, suggestions, assistant, aiActions, snippets, pasteStack

    /// Tools to show for the current feature toggles, in display order.
    static func visible(onePassword: Bool, suggestions: Bool, ai: Bool) -> [SidebarTool] {
        allCases.filter { tool in
            switch tool {
            case .onePassword: return onePassword
            case .scripts: return true
            case .suggestions: return suggestions
            case .assistant, .aiActions: return ai
            case .snippets, .pasteStack: return true
            }
        }
    }

    /// Focus identity of the row.
    var rowID: SidebarRowID {
        switch self {
        case .onePassword: return .onePassword
        case .scripts: return .scripts
        case .suggestions: return .suggestions
        case .assistant: return .assistant
        case .aiActions: return .aiActions
        case .snippets: return .snippets
        case .pasteStack: return .pasteStack
        }
    }

    /// The pane this tool opens.
    var selection: PanelSelection {
        switch self {
        case .onePassword: return .onePassword
        case .scripts: return .scripts
        case .suggestions: return .suggestions
        case .assistant: return .assistant
        case .aiActions: return .aiActions
        case .snippets: return .snippets
        case .pasteStack: return .pasteStack
        }
    }

    /// Visible title.
    var title: String {
        switch self {
        case .onePassword: return "1Password"
        case .scripts: return "Scripts"
        case .suggestions: return "Suggestions"
        case .assistant: return "Assistant"
        case .aiActions: return "AI Actions"
        case .snippets: return "Snippets"
        case .pasteStack: return "Paste Stack"
        }
    }

    /// SF Symbol name.
    var symbol: String {
        switch self {
        case .onePassword: return "key.fill"
        case .scripts: return "terminal.fill"
        case .suggestions, .assistant: return "sparkles"
        case .aiActions: return "wand.and.stars"
        case .snippets: return "text.append"
        case .pasteStack: return "square.stack.3d.down.right"
        }
    }

    /// Tooltip text.
    var help: String {
        switch self {
        case .onePassword: return "Secrets shared to Clippy"
        case .scripts: return "Run saved scripts"
        case .suggestions: return "Clips relevant to what you're doing"
        case .assistant: return "AI Assistant chat"
        case .aiActions: return "Manage AI actions"
        case .snippets: return "Text snippets and expansions"
        case .pasteStack: return "Queue clips and paste them in order"
        }
    }

    /// VoiceOver label (never includes clip content).
    var accessibilityText: String {
        switch self {
        case .onePassword: return "1Password secrets"
        case .assistant: return "AI Assistant"
        default: return title
        }
    }

    /// Row tint.
    @MainActor
    var tint: Color {
        switch self {
        case .onePassword: return AppSettings.shared.theme.accent
        case .scripts: return Color(nsColor: .systemGreen)
        case .suggestions: return Color(nsColor: .systemTeal)
        case .assistant: return Color(nsColor: .systemPurple)
        case .aiActions: return Color(nsColor: .systemIndigo)
        case .snippets: return Color(nsColor: .systemOrange)
        case .pasteStack: return Color(nsColor: .systemBrown)
        }
    }
}
