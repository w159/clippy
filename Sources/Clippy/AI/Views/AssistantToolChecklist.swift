import SwiftUI

/// Multi-step run shown as a checklist: a count header, then one step card per
/// call with the active (running) step marked. A single call renders as a bare card.
struct AssistantToolChecklist: View {
    @Environment(\.clippyTokens) private var tokens
    let steps: [AssistantToolStep]

    var body: some View {
        if steps.count < 2 {
            ForEach(steps) { AssistantToolStepView(step: $0) }
        } else {
            let active = AssistantPresentation.activeStepIndex(steps)
            VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
                Text(AssistantPresentation.checklistHeader(steps))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.textSecondary)
                    .padding(.horizontal, tokens.metrics.space.one)
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    AssistantToolStepView(step: step)
                        .overlay(alignment: .leading) {
                            if index == active {
                                Capsule().fill(tokens.accent).frame(width: 2).padding(.vertical, 3)
                            }
                        }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tool checklist, \(AssistantPresentation.checklistHeader(steps))")
        }
    }
}
