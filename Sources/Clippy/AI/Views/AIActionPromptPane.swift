import SwiftUI

/// Prompt template editor (monospaced, above the fold), variable chips and inline validation.
struct AIActionPromptPane: View {
    @Binding var template: String
    let issues: [AIActionTemplateValidator.Issue]
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            Text("Prompt template").font(.headline).foregroundStyle(tokens.textPrimary)
            TextEditor(text: $template)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(tokens.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(tokens.metrics.space.two)
                .frame(minHeight: 150, maxHeight: 220)
                .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm)
                    .strokeBorder(AIActionTemplateValidator.hasErrors(issues) ? tokens.danger : tokens.strokeStrong, lineWidth: 1))
                .accessibilityLabel("Prompt template")
            HStack(spacing: tokens.metrics.space.two) {
                Text("Insert").font(.caption).foregroundStyle(tokens.textSecondary)
                ForEach(AIActionEditorSupport.variables) { variable in
                    FilterChip(model: FilterChipModel(id: variable.id, title: variable.token, systemImage: "curlybraces",
                                                      accessibilityValue: variable.summary),
                               state: AIActionEditorSupport.isUsed(variable, in: template) ? .selected : .rest) {
                        template = AIActionEditorSupport.inserting(variable, into: template)
                    }
                }
                Spacer(minLength: 0)
            }
            ForEach(issues) { issue in
                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(issue.severity == .error ? tokens.danger : tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
