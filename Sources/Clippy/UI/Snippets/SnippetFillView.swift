import SwiftUI

/// Sheet that collects values for a snippet's `{fill:Label}` fields.
struct SnippetFillView: View {
    /// Snippet being inserted (title only is shown).
    let snippetName: String
    /// Ordered field labels.
    let labels: [String]
    /// Called with the values, or nil when cancelled.
    let onFinish: ([String: String]?) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        ClippySheet(title: "Fill in \(snippetName)") {
            Form {
                ForEach(labels, id: \.self) { label in
                    TextField(label, text: Binding(get: { values[label, default: ""] }, set: { values[label] = $0 }))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Button("Insert") { onFinish(values) }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 380)
    }
}
