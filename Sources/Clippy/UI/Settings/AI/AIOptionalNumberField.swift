import SwiftUI

/// Keeps partially typed decimals in the editor, while persisting only valid values.
struct AIOptionalNumberField: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    var integerOnly = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var issue: String? {
        if text.isEmpty { return nil }
        guard let number = Double(text), number.isFinite, range.contains(number),
              !integerOnly || number.rounded() == number else {
            return "Enter \(integerOnly ? "a whole number" : "a number") from \(range.lowerBound.formatted()) to \(range.upperBound.formatted())."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(title, text: $text, prompt: Text("Provider default"))
                    .focused($focused)
                Button("Provider default") { value = nil; text = "" }.controlSize(.small)
            }
            if let issue { SettingsStatusLine(kind: .failure, text: issue) }
        }
        .task { refresh() }
        .onChange(of: value) { _, _ in if !focused { refresh() } }
        .onChange(of: text) { _, input in
            if input.isEmpty { value = nil }
            else if issue == nil { value = Double(input) }
        }
    }

    private func refresh() {
        text = value.map { integerOnly ? String(Int($0)) : String($0) } ?? ""
    }
}
