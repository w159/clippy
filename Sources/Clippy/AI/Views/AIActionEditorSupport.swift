import Foundation

/// Pure helpers for the AI action editor: variable chips, template insertion and
/// disposition help text. No view or model state, so all of it is unit-testable.
enum AIActionEditorSupport {
    /// A documented template variable offered as an insertable chip.
    struct Variable: Equatable, Identifiable {
        let name: String
        let summary: String
        var id: String { name }
        /// The literal token inserted into a template, e.g. `{clip}`.
        var token: String { "{\(name)}" }
    }

    /// Variables documented on `AIAction`; derived from the validator's known list.
    static let variables: [Variable] = AIActionTemplateValidator.knownPlaceholders.map { name in
        Variable(name: name, summary: name == "clip"
                 ? "The full text of the clip the action runs on."
                 : "An extra instruction asked at run time.")
    }

    /// True when `template` already contains the variable's token.
    static func isUsed(_ variable: Variable, in template: String) -> Bool {
        template.contains(variable.token)
    }

    /// Appends the variable on its own line unless the template is empty or ends with a newline.
    static func inserting(_ variable: Variable, into template: String) -> String {
        if template.isEmpty || template.hasSuffix("\n") { return template + variable.token }
        return template + "\n" + variable.token
    }

    /// One-line explanation of what an output disposition does.
    static func dispositionHelp(_ disposition: AIActionOutputDisposition) -> String {
        switch disposition {
        case .proposeEdit: return "Shows a word-level before/after diff and asks before overwriting the clip."
        case .newClip: return "Inserts the result as a new clip."
        case .copyToClipboard: return "Copies the result to the clipboard without changing any clip."
        }
    }

    /// Short badge word for the action list ("in place", "new clip", "copy").
    static func dispositionBadge(_ disposition: AIActionOutputDisposition) -> String {
        switch disposition {
        case .proposeEdit: return "In place"
        case .newClip: return "New clip"
        case .copyToClipboard: return "Copy"
        }
    }

    /// Placeholder text for the test output area.
    static func testPlaceholder(isTesting: Bool, hasClip: Bool) -> String {
        if isTesting { return "Waiting for the model..." }
        return hasClip ? "Output appears here. Nothing is saved." : "Choose a clip to test against."
    }
}
