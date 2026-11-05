import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ScriptsView {
    // MARK: - Detail pane

    @ViewBuilder var detailPane: some View {
        if editing != nil {
            VStack(spacing: 0) {
                toolbar
                messageRows
                editorAndDrawer
            }
        } else {
            detailEmptyState
        }
    }

    private var detailEmptyState: some View {
        PaneEmptyState(
            systemImage: "applepencil.on.rectangle",
            title: store.scripts.isEmpty ? "No scripts yet" : "No script selected",
            message: store.scripts.isEmpty
                ? "Create a script, then run it from here or the panel."
                : "Pick a script from the list, or create a new one.",
            actionTitle: "New Script") { requestNew() }
    }

    /// Three tiers: labelled controls on one row, icon-only controls on one row, then the name on
    /// its own row above icon-only controls. Every tier keeps all actions reachable.
    var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                nameField.frame(minWidth: 120)
                interpreterPicker
                toolbarActions(compact: false)
            }
            HStack(spacing: 6) {
                nameField.frame(minWidth: 90)
                interpreterPicker
                toolbarActions(compact: true)
            }
            VStack(spacing: 6) {
                nameField
                HStack(spacing: 6) {
                    interpreterPicker
                    toolbarActions(compact: true)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var nameField: some View {
        TextField("Name", text: Binding(get: { editing?.name ?? "" }, set: { editing?.name = $0 }))
            .textFieldStyle(.plain)
            .font(.title3.weight(.semibold))
    }

    private var interpreterPicker: some View {
        Picker("Interpreter", selection: Binding(
            get: { editing?.interpreter ?? .zsh }, set: { editing?.interpreter = $0 })) {
            ForEach(ScriptInterpreter.allCases) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func toolbarActions(compact: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
            Button { showOptions.toggle() } label: {
                if compact { Image(systemName: "slider.horizontal.3") }
                else { Label("Options", systemImage: "slider.horizontal.3") }
            }
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                if let script = editing {
                    ScriptOptionsForm(script: Binding(get: { editing ?? script }, set: { editing = $0 }))
                        .id(script.id)
                }
            }
            .buttonStyle(.glass).tint(nil)
            .help("Arguments, working directory, environment, timeout, interpreter path, stdin")
            .accessibilityLabel("Options")
            Button { showRunHistory.toggle() } label: {
                if compact { Image(systemName: "clock.arrow.circlepath") }
                else { Label("History", systemImage: "clock.arrow.circlepath") }
            }
            .buttonStyle(.glass).tint(nil)
            .disabled(currentHistory.isEmpty)
            .popover(isPresented: $showRunHistory, arrowEdge: .bottom) { historyPopover }
            .help("Run history")
            .accessibilityLabel("History")
            Spacer(minLength: 4)
            Button("Save") { save() }
                .buttonStyle(.glass).tint(nil)
                .keyboardShortcut("s", modifiers: .command)
                .disabled((editing?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true) || (!isDirty && !isDraft))
            if currentRun?.isRunning == true {
                Button { currentRun?.cancel() } label: {
                    if compact { Image(systemName: "stop.fill") } else { Label("Stop", systemImage: "stop.fill") }
                }
                .buttonStyle(.glass).tint(nil)
                .help("Stop").accessibilityLabel("Stop")
            } else {
                Button { activeDialog = .run } label: {
                    if compact { Image(systemName: "play.fill") } else { Label("Run", systemImage: "play.fill") }
                }
                .buttonStyle(.glassProminent)
                .disabled((editing?.body.isEmpty ?? true) || !(editing?.isEnabled ?? false) || preflight != nil)
                .help(preflight ?? "Run the script")
                .accessibilityLabel("Run")
            }
            Menu {
                Button("Duplicate") { duplicateCurrent() }.disabled(isDraft)
                Button("Open in \(ScriptExternalEditor.shared.editorName)") { openExternally() }
                Button("Export\u{2026}") { exportScripts() }
                Divider()
                Button("Delete", role: .destructive) { activeDialog = .delete }
            } label: { ChromeMenuLabel(systemImage: "ellipsis.circle") }
                .chromeMenuStyle()
                .fixedSize()
                .accessibilityLabel("More")
        }
        }
        .controlSize(.regular)
        // Ideal width = real width, so ViewThatFits only picks a tier whose buttons all fit
        // untruncated (Save was clipping to "Sa..." in the middle tier).
        .fixedSize(horizontal: true, vertical: false)
    }

    private var historyPopover: some View {
        ScrollView {
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
                            Text(record.startedAt, format: .dateTime.month().day().hour().minute()).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(record.outcome == .success ? "Success" : (record.outcome == .failed ? "Failed" : record.outcome == .cancelled ? "Cancelled" : "Timed out"))
                                .foregroundStyle(tokens.textSecondary).lineLimit(1)
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
        }
        .frame(minWidth: 220, maxWidth: 360, maxHeight: 280)
    }

    @ViewBuilder var messageRows: some View {
        if let preflight {
            Label(preflight, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if editing?.isEnabled == false {
            Label("Disabled scripts cannot run. Review the body, then enable it in Options.",
                  systemImage: "exclamationmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let saveOutcome {
            HStack(spacing: 6) {
                if saveOutcome == .saved {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Could not save script", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try Again") { save() }.buttonStyle(.glass).tint(nil).controlSize(.small)
                }
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 4)
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
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
