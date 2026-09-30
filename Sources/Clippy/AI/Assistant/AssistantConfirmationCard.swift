import SwiftUI

// MARK: - Inline approval card

/// Inline numbered option card shown in the panel when a tool whose policy is
/// "ask" is called (no modal). The complete call, including any code, is shown in a
/// scrollable monospaced box (AI-07). Keys 1-3 pick an option; Skip, Return and Esc
/// deny this call, so a stray Return can never approve a code-executing tool.
struct AssistantConfirmationCard: View {
    let toolName: String
    let prompt: String
    let onChoose: (AssistantPresentation.ApprovalChoice) -> Void
    /// Skips this call without running it (same effect as Deny for the call).
    let onSkip: () -> Void
    @Environment(\.clippyTokens) private var tokens
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            Label {
                Text("Allow \(toolName) to run?").foregroundStyle(tokens.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(tokens.warning)
            }
            .font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(prompt)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(tokens.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 200)
            .padding(tokens.metrics.space.two)
            .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
            .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.strokeStrong, lineWidth: 1))
            .accessibilityLabel("Full call for \(toolName)")
            VStack(spacing: tokens.metrics.space.one) {
                ForEach(AssistantPresentation.ApprovalChoice.allCases, id: \.self) { choice in optionRow(choice) }
            }
            HStack {
                Text("Return or Esc denies").font(.caption).foregroundStyle(tokens.textSecondary)
                Spacer()
                Button("Skip", action: onSkip).buttonStyle(.plain).foregroundStyle(tokens.textSecondary)
                    .accessibilityHint("Skips this call without running it")
            }
        }
        .padding(tokens.metrics.space.four)
        .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.md))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.md).strokeBorder(tokens.strokeStrong, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            if let choice = AssistantPresentation.ApprovalChoice.choice(forKey: press.characters) {
                onChoose(choice)
                return .handled
            }
            if press.key == .return { onChoose(.deny); return .handled }
            return .ignored
        }
        .onExitCommand { onChoose(.deny) }
    }

    private func optionRow(_ choice: AssistantPresentation.ApprovalChoice) -> some View {
        Button { onChoose(choice) } label: {
            HStack(spacing: tokens.metrics.space.two) {
                KeyCap(choice.keyHint)
                Text(choice.title).font(.callout.weight(.medium)).foregroundStyle(tokens.textPrimary)
                Text(choice.detail).font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, tokens.metrics.space.two)
            .padding(.vertical, tokens.metrics.space.one + 2)
            .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title). \(choice.detail). Key \(choice.keyHint)")
    }
}
