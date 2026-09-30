import SwiftUI

/// A captioned single-line text field drawn as a bordered inset, matching the API key field.
struct AIInsetField: View {
    @Environment(\.clippyTokens) private var tokens
    let title: String
    @Binding var text: String
    var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Text(title).font(.caption).foregroundStyle(tokens.textSecondary)
            TextField(title, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .accessibilityLabel(title)
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, tokens.metrics.space.three)
                .frame(minHeight: 32)
                .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous).stroke(tokens.stroke, lineWidth: 1))
        }
        .padding(.vertical, tokens.metrics.space.two)
    }
}
