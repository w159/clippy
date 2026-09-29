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
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            HStack {
                Text("Test").font(.headline).foregroundStyle(tokens.textPrimary)
                Spacer()
                if isTesting {
                    Button("Stop", action: onStop).keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Run test", action: onRun).disabled(!canRun).buttonStyle(.borderedProminent).tint(tokens.accent)
                }
            }
            Picker("Clip", selection: $clipID) {
                Text("Choose a clip").tag(Int64?.none)
                ForEach(clips, id: \.id) { clip in Text(clip.displayTitle).lineLimit(1).tag(clip.id) }
            }
            if showsInstruction { TextField("Instruction for the test", text: $instruction).textFieldStyle(.roundedBorder) }
            outputArea
        }
    }

    private var outputArea: some View {
        ScrollView {
            Group {
                if let errorText {
                    Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(tokens.danger)
                } else if output.isEmpty && isTesting {
                    VStack(alignment: .leading, spacing: 6) { Skeleton(width: 200, height: 10); Skeleton(width: 140, height: 10) }
                        .accessibilityLabel("Waiting for the model")
                } else if output.isEmpty {
                    Text(AIActionEditorSupport.testPlaceholder(isTesting: isTesting, hasClip: clipID != nil))
                        .foregroundStyle(tokens.textSecondary)
                } else {
                    Text(output).foregroundStyle(tokens.textPrimary)
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(tokens.metrics.space.two)
        }
        .frame(maxHeight: .infinity)
        .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.stroke, lineWidth: 1))
        .accessibilityLabel("Test output")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
