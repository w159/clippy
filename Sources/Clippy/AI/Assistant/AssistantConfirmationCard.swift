import SwiftUI

// MARK: - Inline confirmation card

/// Shown as an overlay when a tool whose policy is "ask" is called. The complete
/// call, including any code, is shown in a scrollable monospaced box (AI-07).
struct AssistantConfirmationCard: View {
    let toolName: String
    let prompt: String
    let onAllow: () -> Void
    let onDeny: () -> Void
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            Label {
                Text("Confirm action").foregroundStyle(tokens.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(tokens.warning)
            }
            .font(.headline)
            Text("The assistant wants to call \(toolName). Review the full call before allowing.")
                .font(.callout).foregroundStyle(tokens.textSecondary)
            ScrollView([.vertical, .horizontal]) {
                Text(prompt)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(tokens.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 320)
            .padding(tokens.metrics.space.two)
            .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
            .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.strokeStrong, lineWidth: 1))
            .accessibilityLabel("Full call for \(toolName)")
            HStack {
                // The safe choice (Deny) is the default Return action; Allow needs Cmd-Return
                // so a stray Enter cannot approve a code-executing tool.
                Button("Deny", role: .cancel, action: onDeny).keyboardShortcut(.return, modifiers: [])
                Spacer()
                Button("Allow", action: onAllow)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(tokens.accent)
                    .help("Press Cmd-Return to allow")
            }
        }
        .padding(tokens.metrics.space.five)
        .frame(maxWidth: 560)
        .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.md))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.md).strokeBorder(tokens.strokeStrong, lineWidth: 1))
        .shadow(color: tokens.metrics.elevation.color, radius: tokens.metrics.elevation.e2)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        // Escape also denies, in addition to Return above.
        .onExitCommand { onDeny() }
    }
}
