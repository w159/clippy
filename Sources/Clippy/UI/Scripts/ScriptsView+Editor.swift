import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ScriptsView {
    // MARK: - Detail pane

    @ViewBuilder var detailPane: some View {
        if editing != nil {
            VStack(spacing: 0) {
                toolbar
                Divider()
                messageRows
                editorAndDrawer
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "applepencil.on.rectangle")
                    .font(.system(size: 30, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.textSecondary)
                Text(store.scripts.isEmpty ? "No scripts yet" : "No script selected")
                    .font(.headline)
                    .foregroundStyle(tokens.textPrimary)
                Text("Click + to create a script, then run it from here or the panel.")
                    .font(.subheadline)
                    .foregroundStyle(tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One row when it fits; otherwise the name gets its own row above the actions.
    var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { nameField; HStack(spacing: 8) { toolbarControls }.fixedSize() }
                .padding(10)
            VStack(spacing: 6) {
                nameField
                HStack(spacing: 8) { toolbarControls }.fixedSize()
            }
            .padding(10)
            VStack(spacing: 6) {
                nameField
                HStack(spacing: 8) { toolbarControls }.fixedSize().labelStyle(.iconOnly)
            }
            .padding(10)
        }
    }

    private var nameField: some View {
        TextField("Name", text: Binding(get: { editing?.name ?? "" }, set: { editing?.name = $0 }))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120)
    }

    @ViewBuilder private var toolbarControls: some View {
            Picker("Interpreter", selection: Binding(
                get: { editing?.interpreter ?? .zsh }, set: { editing?.interpreter = $0 })) {
                ForEach(ScriptInterpreter.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { showOptions.toggle() } label: { Label("Options", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                    if let script = editing {
                        ScriptOptionsForm(script: Binding(get: { editing ?? script }, set: { editing = $0 }))
                            .id(script.id)
                    }
                }
                .help("Arguments, working directory, environment, timeout, interpreter path, stdin")
            Spacer(minLength: 4)
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled((editing?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true) || (!isDirty && !isDraft))
            Button { showRunHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                .disabled(currentHistory.isEmpty)
                .popover(isPresented: $showRunHistory, arrowEdge: .bottom) { historyPopover }
            if currentRun?.isRunning == true {
                Button { currentRun?.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { activeDialog = .run } label: { Label("Run", systemImage: "play.fill") }
                    .disabled((editing?.body.isEmpty ?? true) || !(editing?.isEnabled ?? false) || preflight != nil)
                    .help(preflight ?? "Run the script")
            }
            Menu {
                Button("Duplicate") { duplicateCurrent() }.disabled(isDraft)
                Button("Open in \(ScriptExternalEditor.shared.editorName)") { openExternally() }
                Button("Export...") { exportScripts() }
                Divider()
                Button("Delete", role: .destructive) { activeDialog = .delete }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent runs").font(.headline)
            ForEach(currentHistory) { record in
                Button {
                    historyDetail = record
                    drawerTab = .history
                    showRunHistory = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(for: record.outcome))
                            .foregroundStyle(Self.color(for: record.outcome, tokens: tokens))
                        Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        Text(record.outcome == .success ? "Success" : (record.outcome == .failed ? "Failed" : record.outcome == .cancelled ? "Cancelled" : "Timed out"))
                            .foregroundStyle(tokens.textSecondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.historyAccessibilityLabel(for: record))
            }
        }
        .padding(12)
        .frame(width: 300, height: min(280, CGFloat(max(1, currentHistory.count)) * 32 + 42))
    }

    @ViewBuilder var messageRows: some View {
        if let preflight {
            Label(preflight, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(tokens.danger)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if editing?.isEnabled == false {
            Label("Disabled scripts cannot run. Review the body, then enable it in Options.",
                  systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(tokens.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let saveOutcome {
            HStack(spacing: 6) {
                if saveOutcome == .saved {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(tokens.success)
                } else {
                    Label("Could not save script", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(tokens.danger)
                    Button("Retry") { save() }.controlSize(.small)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var editorAndDrawer: some View {
        ScriptDrawerLayout(showsDrawer: currentRun != nil || !currentHistory.isEmpty) {
            CodeEditorView(
                text: Binding(get: { editing?.body ?? "" }, set: { editing?.body = $0 }),
                language: editing?.interpreter.codeLanguage ?? .plain,
                documentID: editing?.id,
                accessibilityLabel: "Script body",
                onSave: { save() })
                .frame(minHeight: OutputDrawerMetrics.minEditorHeight, maxHeight: .infinity)
        } drawer: {
            drawer
        }
        .task(id: PreflightKey(interpreter: editing?.interpreter ?? .zsh,
                               custom: editing?.customInterpreterPath ?? "",
                               directory: editing?.workingDirectory ?? "",
                               id: editing?.id)) { await refreshPreflight() }
    }
}

extension ScriptsView {
    /// VoiceOver label for a run-history row: the outcome, then when it ran.
    static func historyAccessibilityLabel(for record: ScriptRunRecord) -> String {
        let outcome: String
        switch record.outcome {
        case .success: outcome = "Success"
        case .failed: outcome = "Failed"
        case .cancelled: outcome = "Cancelled"
        case .timedOut: outcome = "Timed out"
        }
        let when = record.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(outcome), run at \(when)"
    }
}
