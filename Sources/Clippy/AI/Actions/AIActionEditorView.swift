import SwiftUI

/// Two-pane editor for an AIAction (AI-14): name, icon, output and model on the left;
/// prompt template, validation and a live streamed test against a chosen clip on the
/// right. Nothing from a test run is ever written anywhere.
struct AIActionEditorView: View {
    let initial: AIAction?
    let onSave: (AIAction) -> Void
    let onCancel: () -> Void

    @Environment(\.clippyTokens) private var tokens
    @State private var name: String
    @State private var iconKind: CategoryIconKind
    @State private var symbolName: String
    @State private var promptTemplate: String
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var outputDisposition: AIActionOutputDisposition
    @State private var showIconPicker = false

    @State private var testClips: [Clip] = []
    @State private var testClipID: Int64?
    @State private var testInstruction = ""
    @State private var testOutput = ""
    @State private var testError: String?
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?

    init(action: AIAction?, onSave: @escaping (AIAction) -> Void, onCancel: @escaping () -> Void) {
        self.initial = action
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: action?.name ?? "")
        _iconKind = State(initialValue: action?.iconKind ?? .symbol)
        _symbolName = State(initialValue: action?.symbolName ?? "wand.and.sparkles")
        _promptTemplate = State(initialValue: action?.promptTemplate ?? "")
        _temperature = State(initialValue: action?.temperature ?? 0.4)
        _maxTokens = State(initialValue: action?.maxTokens ?? 512)
        _outputDisposition = State(initialValue: action?.outputDisposition ?? .proposeEdit)
    }

    private var issues: [AIActionTemplateValidator.Issue] { AIActionTemplateValidator.validate(promptTemplate) }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !AIActionTemplateValidator.hasErrors(issues)
    }
    private var testClip: Clip? { testClips.first { $0.id == testClipID } }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(tokens.stroke)
            HStack(alignment: .top, spacing: 0) {
                settingsPane.frame(width: 300)
                Divider().overlay(tokens.stroke)
                rightPane
            }
            Divider().overlay(tokens.stroke)
            Text("Cmd-S saves. Cancel discards your edits.")
                .font(.caption).foregroundStyle(tokens.textSecondary).padding(tokens.metrics.space.two)
        }
        .background(tokens.surface)
        .frame(width: 900, height: 600)
        .onAppear(perform: loadTestClips)
        .onDisappear { testTask?.cancel() }
    }

    private var titleBar: some View {
        HStack {
            Text(initial == nil ? "New Action" : "Edit Action").font(.title3.weight(.semibold)).foregroundStyle(tokens.textPrimary)
            Spacer()
            Button("Cancel") { testTask?.cancel(); onCancel() }.keyboardShortcut(.cancelAction)
            Button("Save") { testTask?.cancel(); onSave(draft()) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(tokens.accent)
                .disabled(!isValid)
        }
        .padding(.horizontal, tokens.metrics.space.five)
        .padding(.vertical, tokens.metrics.space.three)
    }

    // MARK: Left pane

    private var settingsPane: some View {
        Form {
            Section("Name and icon") {
                TextField("Action name", text: $name)
                LabeledContent("Icon") {
                    Button { showIconPicker.toggle() } label: {
                        HStack(spacing: tokens.metrics.space.two) {
                            ActionIconView(kind: iconKind, value: symbolName).frame(width: 20)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel("Choose icon")
                    // The picker lives in a popover so it is never nested in this form's scroller.
                    .popover(isPresented: $showIconPicker) {
                        IconPickerView(iconKind: $iconKind, iconValue: $symbolName)
                            .padding(tokens.metrics.space.three)
                            .frame(width: 320, height: 300)
                    }
                }
            }
            Section("Output") {
                ClippySegmentedPicker("Result", selection: $outputDisposition, options: AIActionOutputDisposition.allCases.map {
                    SegmentOption(value: $0, title: AIActionEditorSupport.dispositionBadge($0))
                })
                Text(AIActionEditorSupport.dispositionHelp(outputDisposition)).font(.caption).foregroundStyle(tokens.textSecondary)
            }
            Section("Model") {
                LabeledContent("Temperature \(temperature, format: .number.precision(.fractionLength(1)))") {
                    Slider(value: $temperature, in: 0...1, step: 0.1)
                }
                Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 16...4096, step: 64)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Right pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            AIActionPromptPane(template: $promptTemplate, issues: issues)
            Divider().overlay(tokens.stroke)
            AIActionTestPanel(
                clips: testClips, clipID: $testClipID, instruction: $testInstruction,
                showsInstruction: promptTemplate.contains("{instruction}"),
                output: testOutput, errorText: testError, isTesting: isTesting,
                canRun: testClip != nil && !AIActionTemplateValidator.hasErrors(issues),
                onRun: runTest, onStop: { testTask?.cancel() })
        }
        .padding(tokens.metrics.space.four)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Actions

    private func loadTestClips() {
        testClips = (try? ClipDatabase.shared.recentTextClips(limit: 30)) ?? []
        testClipID = testClips.first?.id
    }

    /// The action as currently edited. Editing keeps the original id, built-in flag
    /// and sortOrder, so saving does not reorder the list (AI-09).
    private func draft() -> AIAction {
        let symbol = iconKind == .symbol && symbolName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "wand.and.sparkles" : symbolName
        return AIAction(
            id: initial?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            iconKind: iconKind,
            symbolName: symbol,
            promptTemplate: promptTemplate,
            temperature: temperature,
            maxTokens: maxTokens,
            outputDisposition: outputDisposition,
            isBuiltIn: initial?.isBuiltIn ?? false,
            sortOrder: initial?.sortOrder ?? 0
        )
    }

    private func runTest() {
        guard let clip = testClip else { return }
        switch AIService.fromSettings() {
        case .failure(let error):
            testError = error.localizedDescription
        case .success(let service):
            testError = nil
            testOutput = ""
            isTesting = true
            let action = draft()
            let instruction = testInstruction
            testTask = Task { @MainActor in
                defer { isTesting = false }
                do {
                    _ = try await service.run(action: action, on: clip.contentText, instruction: instruction) { partial in
                        Task { @MainActor in testOutput = partial }
                    }
                } catch is CancellationError {
                    // Stopped by the user.
                } catch {
                    testError = error.localizedDescription
                }
            }
        }
    }
}

#Preview("Action editor") {
    AIActionEditorView(action: AIAction.builtIns.first, onSave: { _ in }, onCancel: {})
        .clippyDesignSystem()
}
