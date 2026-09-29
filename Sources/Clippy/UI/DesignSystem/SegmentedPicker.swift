import SwiftUI

/// A typed option for the native segmented control.
struct SegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String? = nil
    var id: Value { value }
}

/// Native SwiftUI segmented picker that preserves platform keyboard and AX behavior.
struct ClippySegmentedPicker<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [SegmentOption<Value>]
    private let label: String
    private let disabled: Bool

    /// Creates a native two-to-four-option segmented picker.
    init(_ label: String, selection: Binding<Value>, options: [SegmentOption<Value>], disabled: Bool = false) {
        self.label = label
        self._selection = selection
        self.options = options
        self.disabled = disabled
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { option in
                if let symbol = option.systemImage {
                    Label(option.title, systemImage: symbol).tag(option.value)
                } else {
                    Text(option.title).tag(option.value)
                }
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}
