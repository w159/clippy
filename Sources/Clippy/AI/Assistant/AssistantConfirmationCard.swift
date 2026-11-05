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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Allow \(toolName) to run?")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Color.orange)
            }
            .font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(prompt)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 200)
            .padding(10)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Full call for \(toolName)")
            VStack(spacing: 6) {
                ForEach(AssistantPresentation.ApprovalChoice.allCases, id: \.self) { choice in optionRow(choice) }
            }
            HStack {
                Text("Return or Esc denies").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Skip", action: onSkip).buttonStyle(.glass).controlSize(.small)
                    .accessibilityHint("Skips this call without running it")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            HStack(spacing: 8) {
                KeyCap(choice.keyHint)
                Text(choice.title).font(.callout.weight(.medium))
                Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title). \(choice.detail). Key \(choice.keyHint)")
    }
}
