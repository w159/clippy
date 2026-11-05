import SwiftUI

/// Prompt template editor (monospaced, above the fold), variable chips and inline validation.
struct AIActionPromptPane: View {
    @Binding var template: String
    let issues: [AIActionTemplateValidator.Issue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt template").font(.headline)
            TextEditor(text: $template)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 150, maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if AIActionTemplateValidator.hasErrors(issues) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                    }
                }
                .accessibilityLabel("Prompt template")
            HStack(spacing: 8) {
                Text("Insert").font(.caption).foregroundStyle(.secondary)
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
                    .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
