import SwiftUI

/// Settings for the paste stack and copy-twice-to-append (FEAT-06, FEAT-13).
/// Reads and writes `AppendPreferences`; clip content never leaves the device.
struct PasteStackSettingsPane: View {
    @State private var order = AppendPreferences.stackOrder
    @State private var appendEnabled = AppendPreferences.isEnabled
    @State private var window = AppendPreferences.window
    @State private var separator = AppendPreferences.separator
    @State private var mergeSeparator = AppendPreferences.mergeSeparator

    init() {}

    var body: some View {
        Form {
            Section {
                Picker("Paste order", selection: $order) {
                    ForEach(PasteStackOrder.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: order) { _, value in
                    AppendPreferences.stackOrder = value
                    PasteStack.shared.order = value
                }
            } header: {
                Label("Paste stack", systemImage: "square.stack.3d.up")
            } footer: {
                Text("The stack lives in memory only and is cleared when Clippy quits. Sensitive clips are never added.")
            }
            Section {
                Toggle("Append a second copy to the first", isOn: $appendEnabled)
                    .onChange(of: appendEnabled) { _, value in AppendPreferences.isEnabled = value }
                HStack {
                    Text("Within")
                    Slider(value: $window, in: AppendPreferences.windowRange, step: 0.1)
                        .onChange(of: window) { _, value in AppendPreferences.window = value }
                    Text(String(format: "%.1f s", window)).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .disabled(!appendEnabled)
                Picker("Separator", selection: $separator) {
                    ForEach(MergeSeparator.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: separator) { _, value in AppendPreferences.separator = value }
                .disabled(!appendEnabled)
            } header: {
                Label("Copy twice to append", systemImage: "plus.square.on.square")
            } footer: {
                Text("Two copies from the same app inside the window become one clip. Sensitive copies are never appended.")
            }
            Section("Merge selected clips") {
                Picker("Separator", selection: $mergeSeparator) {
                    ForEach(MergeSeparator.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: mergeSeparator) { _, value in AppendPreferences.mergeSeparator = value }
            }
            SettingsPaneActionsSection()
        }
        .formStyle(.grouped)
    }
}
