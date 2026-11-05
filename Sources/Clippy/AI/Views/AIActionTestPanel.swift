import SwiftUI

/// Live test panel: clip picker, optional instruction, Run/Stop and streaming
/// output. Output is display-only and never persisted.
struct AIActionTestPanel: View {
    let clips: [Clip]
    @Binding var clipID: Int64?
    @Binding var instruction: String
    let showsInstruction: Bool
    let output: String
    let errorText: String?
    let isTesting: Bool
    let canRun: Bool
    let onRun: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Test").font(.headline)
                Spacer()
                if isTesting {
                    Button("Stop", action: onStop).buttonStyle(.glass).keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Run test", action: onRun).disabled(!canRun).buttonStyle(.glassProminent)
                }
            }
            Picker("Clip", selection: $clipID) {
                Text("Choose a clip").tag(Int64?.none)
                ForEach(clips, id: \.id) { clip in Text(clip.displayTitle).lineLimit(1).tag(clip.id) }
            }
            if showsInstruction { TextField("Instruction for the test", text: $instruction).textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
            outputArea
        }
    }

    private var outputArea: some View {
        ScrollView {
            Group {
                if let errorText {
                    Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else if output.isEmpty && isTesting {
                    VStack(alignment: .leading, spacing: 6) { Skeleton(width: 200, height: 10); Skeleton(width: 140, height: 10) }
                        .accessibilityLabel("Waiting for the model")
                } else if output.isEmpty {
                    Text(AIActionEditorSupport.testPlaceholder(isTesting: isTesting, hasClip: clipID != nil))
                        .foregroundStyle(.secondary)
                } else {
                    Text(output)
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Test output")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
