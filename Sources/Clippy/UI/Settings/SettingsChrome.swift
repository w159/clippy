import AppKit
import SwiftUI

// Shared settings chrome: status outcome, validated text field, and window appearance applier.

/// A typed test/install outcome so the UI can render success and failure with
/// distinct icons and colors. Audit finding: test-connection results were
/// rendered as plain secondary Text with no success/failure visual distinction.
/// This mirrors the key-save pattern (checkmark/xmark + colored) already used
/// for the API-key save indicator.
struct StatusOutcome: Equatable {
    let succeeded: Bool
    let message: String
}

struct StatusOutcomeLabel: View {
    let outcome: StatusOutcome
    var successColor: Color
    var failureColor: Color

    init(outcome: StatusOutcome, successColor: Color, failureColor: Color? = nil) {
        self.outcome = outcome
        self.successColor = successColor
        self.failureColor = failureColor ?? StatusOutcomeLabel.defaultFailure
    }

    /// Failure role when the caller does not pass one; the design-system danger hue.
    static var defaultFailure: Color { Color(nsColor: .systemRed) }

    var body: some View {
        Label {
            Text(outcome.message)
        } icon: {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .font(.caption)
        .foregroundStyle(outcome.succeeded ? successColor : failureColor)
        .textSelection(.enabled)
    }
}

/// A TextField that validates on commit (not per keystroke) and shows an inline
/// error. Audit finding: AI endpoint URL, model, and 1Password vault name had
/// no inline validation. Reuses the CustomColorRow commit pattern: a local
/// draft so a half-typed invalid value never writes through to settings.
struct ValidatedTextField: View {
    let title: String
    var prompt: Text? = nil
    @Binding var value: String
    /// Returns an error message when the committed input is invalid, nil when
    /// it is acceptable. Empty string handling is the caller's responsibility.
    let validate: (String) -> String?

    @Environment(\.clippyTokens) private var tokens
    @FocusState private var focused: Bool
    @State private var draft: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: $draft, prompt: prompt)
                .focused($focused)
                .onSubmit { commit() }
                // SET-06: commit when focus leaves the field, not only on Return.
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .foregroundStyle(error != nil ? tokens.danger : tokens.textPrimary)
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(tokens.danger)
            }
        }
        .onAppear { draft = value }
        // Keep the draft in sync when the stored value changes elsewhere
        // (reset-to-defaults, another window) so the field does not show stale
        // text after an external change.
        .onChange(of: value) { _, newValue in
            if newValue != draft { draft = newValue; error = nil }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let msg = validate(trimmed) {
            error = msg
            return
        }
        error = nil
        value = trimmed
        draft = trimmed
    }
}

/// Pushes an NSAppearance onto the hosting window. Used so changing the theme
/// repaints the settings window (a grouped Form) in matching light/dark.
struct WindowAppearanceApplier: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = appearance
        // The hosting window is often nil during the first layout pass, so defer
        // to the next runloop turn. Apply only when the value actually changed to
        // avoid redundant repaints, and no-op while the window is still nil.
        Task { @MainActor in
            guard let window = view.window, window.appearance != target else { return }
            window.appearance = target
        }
    }
}
