import AppKit
import SwiftUI

/// Manage and run stored scripts. Picking a script loads it into an editor;
/// Run executes it in a subprocess (after a confirmation) and shows the output.
struct ScriptsView: View {
    @ObservedObject private var store = ScriptStore.shared
    // Theme tokens drive surfaces/borders/text so a theme switch repaints this view.
    @ObservedObject private var settings = AppSettings.shared
    private var tokens: ThemeTokens { settings.theme }

    @State private var selection: UUID?
    @State private var editing = Script(name: "")
    /// Script currently being run (keyed by id so a stale Task cannot paint its
    /// output under the wrong script after the user switches selection).
    @State private var runningScriptID: UUID?
    @State private var runTask: Task<Void, Never>?
    @State private var result: ScriptResult?
    @State private var draggingOverScriptID: String?
    @State private var searchQuery = ""
    // Dirty-discard gate: when the user switches scripts with unsaved edits, ask
    // before replacing the editor contents.
    @State private var pendingNav: PendingNav?
    // Single dialog driver. Consolidating run/discard/delete into one enum-driven
    // confirmationDialog avoids the "only one .confirmationDialog fires" pitfall
    // when several are stacked on the same view.
    @State private var activeDialog: Dialog?
    // Save feedback (success banner / error banner with Retry).
    @State private var saveOutcome: SaveOutcome?

    private enum PendingNav: Equatable { case select(UUID), newScript }
    private enum SaveOutcome: Equatable { case saved, failed }
    private enum Dialog: Equatable { case run, discard, delete }

    /// True when the editor holds edits that differ from the stored script
    /// (or, for an unsaved script, when any field has content). Drives the
    /// discard-confirmation gate on selection change.
    private var isDirty: Bool {
        if let stored = store.script(id: editing.id) {
            return stored.name != editing.name
                || stored.interpreter != editing.interpreter
                || stored.body != editing.body
                || stored.feedsClipboard != editing.feedsClipboard
                || stored.outputToClipboard != editing.outputToClipboard
        }
        return !editing.name.isEmpty || !editing.body.isEmpty
    }

    private var isRunning: Bool { runningScriptID == editing.id }

    private var filteredScripts: [Script] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.scripts }
        return store.scripts.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.scripts.isEmpty {
                emptyState
            } else {
                editor
            }
        }
        // Do not auto-create a blank script on appear (the audit flagged that it
        // suppressed the true empty state). Show the empty state instead; the +
        // button creates the first script on demand.
        .onAppear { select(store.scripts.first?.id) }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(
                get: { activeDialog != nil },
                set: { if !$0 { activeDialog = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch activeDialog {
            case .run:
                Button("Run", role: .destructive) { performRun(); activeDialog = nil }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            case .discard:
                Button("Discard", role: .destructive) {
                    if let nav = pendingNav {
                        switch nav {
                        case .select(let id): performSelect(id)
                        case .newScript: performNew()
                        }
                    }
                    pendingNav = nil
                    activeDialog = nil
                }
                Button("Cancel", role: .cancel) { pendingNav = nil; activeDialog = nil }
            case .delete:
                Button("Delete", role: .destructive) { performDelete(); activeDialog = nil }
                Button("Cancel", role: .cancel) { activeDialog = nil }
            case nil:
                EmptyView()
            }
        } message: {
            switch activeDialog {
            case .run:
                Text("This executes code on your Mac with your user permissions.")
            case .discard:
                Text("Switching scripts will lose your edits to the current one.")
            case .delete:
                Text("This removes the script from your saved list. This cannot be undone.")
            case nil:
                EmptyView()
            }
        }
    }

    private var dialogTitle: String {
        switch activeDialog {
        case .run:
            return "Run \"\(editing.name.isEmpty ? "Untitled" : editing.name)\"?"
        case .discard:
            return "Discard unsaved changes?"
        case .delete:
            let name = store.script(id: selection ?? UUID())?.name ?? "Untitled"
            return "Delete \"\(name)\"?"
        case nil:
            return ""
        }
    }

    // MARK: - Empty state (#16: show a real empty state instead of auto-creating)

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "applepencil.on.rectangle")
                .font(.system(size: 30, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
            Text("No scripts yet")
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

    // MARK: - Header (script list + add/delete)

    private var header: some View {
        VStack(spacing: 0) {
            // Toolbar row: title + add/delete buttons
            HStack {
                Text("Scripts")
                    .font(.headline)
                Spacer()
                Button { newScript() } label: { Image(systemName: "plus") }
                    .help("New script")
                Button { deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete script")
                    .disabled(selection == nil)
            }
            .padding(10)
            Divider()
            // Search field above the list so a long script list can be narrowed.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.textSecondary)
                TextField("Search scripts", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            // Reorderable script list. Rows are Buttons (keyboard-focusable and
            // VoiceOver-announced as actionable); the drag handle carries
            // .reorderDraggable so it does not compete with the Button's tap.
            ScrollView {
                LazyVStack(spacing: 2) {
                    // "New script" row mirrors the old Picker's nil-tag entry.
                    Button {
                        newScript()
                    } label: {
                        HStack {
                            Text("New script")
                                .font(.body)
                                .foregroundStyle(selection == nil ? Color.accentColor : tokens.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            selection == nil
                                ? tokens.cardSurface
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(filteredScripts) { script in
                        Button {
                            select(script.id)
                        } label: {
                            HStack(spacing: 6) {
                                // Explicit drag handle so .draggable does not fight
                                // the Button's tap. The whole row stays a Button for
                                // keyboard focus and VoiceOver "actionable" role.
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 9))
                                    .foregroundStyle(tokens.textSecondary)
                                    .reorderDraggable(id: script.id.uuidString)
                                    .help("Drag to reorder")
                                Text(script.name.isEmpty ? "Untitled" : script.name)
                                    .font(.body)
                                    .foregroundStyle(
                                        selection == script.id
                                            ? Color.accentColor
                                            : tokens.textPrimary
                                    )
                                    .lineLimit(1)
                                Spacer()
                                Text(script.interpreter.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(tokens.textSecondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                selection == script.id
                                    ? tokens.cardSurface
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        selection == script.id
                                            ? tokens.cardBorder
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == script.id ? .isSelected : [])
                        .reorderDropDestination(
                            id: script.id.uuidString,
                            draggingOver: $draggingOverScriptID
                        ) { draggedStr, targetStr in
                            if let d = UUID(uuidString: draggedStr),
                               let t = UUID(uuidString: targetStr) {
                                store.moveScript(draggedID: d, before: t)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 160)
            Divider()
        }
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $editing.name)
                    .textFieldStyle(.roundedBorder)

                Picker("Interpreter", selection: $editing.interpreter) {
                    ForEach(ScriptInterpreter.allCases) { Text($0.displayName).tag($0) }
                }

                PlainTextEditor(text: $editing.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))

                Toggle("Feed the current clipboard text to the script (stdin and $CLIPPY_CLIP)",
                       isOn: $editing.feedsClipboard)
                Toggle("Offer the output as a new clip when it finishes",
                       isOn: $editing.outputToClipboard)

                HStack {
                    Button("Save") { save() }
                        .disabled(editing.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(isRunning ? "Running..." : "Run") { activeDialog = .run }
                        .disabled(isRunning || editing.body.isEmpty)
                    Spacer()
                }

                // Save feedback: themed success banner or an error banner with
                // Retry. ScriptStore.add/update now return whether the write
                // persisted, so a failed save is surfaced instead of dropped.
                if let saveOutcome {
                    HStack(spacing: 6) {
                        if saveOutcome == .saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Could not save script", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Retry") { save() }
                                .controlSize(.small)
                        }
                    }
                    .font(.caption)
                }

                if isRunning {
                    // Cancel path: the Task handle lets us abort a run before the
                    // 30s timeout. ScriptRunner owns the Process and terminates it
                    // on Task.cancel().
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running...").font(.caption).foregroundStyle(tokens.textSecondary)
                        Spacer()
                        Button("Cancel") { stopRun() }
                            .controlSize(.small)
                    }
                    .help("The script is still running.")
                }
                if let result {
                    outputView(result)
                }
            }
            .padding(12)
        }
    }

    private func outputView(_ result: ScriptResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Green/red are kept here: they carry true success/failure status,
                // for which the token table has no semantic color.
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                Text(result.timedOut ? "Timed out" : "Exit \(result.exitCode) - \(result.durationMs) ms")
                    .font(.caption)
                    .foregroundStyle(tokens.textPrimary)
                Spacer()
                if !result.stdout.isEmpty {
                    Button("Copy output") { copyToPasteboard(result.stdout) }
                        .controlSize(.small)
                }
            }
            // Truncation banner: the runner hit the 5 MB stream ceiling. Distinct
            // from the display cap applied per box below.
            if result.truncated {
                Label("Output truncated: hit the capture ceiling", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !result.stdout.isEmpty { outputBox(ScriptResult.displayCapped(result.stdout), mono: true) }
            if !result.stderr.isEmpty {
                Text("stderr").font(.caption2).foregroundStyle(tokens.textSecondary)
                outputBox(ScriptResult.displayCapped(result.stderr), mono: true)
            }
        }
        .padding(8)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tokens.cardBorder))
    }

    private func outputBox(_ text: String, mono: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(tokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 140)
    }

    // MARK: - Actions

    private func newScript() {
        if isDirty {
            pendingNav = .newScript
            activeDialog = .discard
            return
        }
        performNew()
    }

    private func performNew() {
        editing = Script(name: "")
        selection = nil
        result = nil
    }

    private func select(_ id: UUID?) {
        // Re-clicking the current selection is a no-op; do not prompt to discard.
        if id == selection { return }
        if isDirty {
            pendingNav = id.map { PendingNav.select($0) } ?? .newScript
            activeDialog = .discard
            return
        }
        performSelect(id)
    }

    private func performSelect(_ id: UUID?) {
        result = nil
        guard let id, let script = store.script(id: id) else {
            // No selection: blank editor without creating a script.
            editing = Script(name: "")
            selection = nil
            return
        }
        editing = script
        selection = id
    }

    private func save() {
        let wasNew = store.script(id: editing.id) == nil
        let ok = wasNew ? store.add(editing) : store.update(editing)
        if ok {
            saveOutcome = .saved
            selection = editing.id
        } else {
            saveOutcome = .failed
        }
        // Auto-clear success after a short delay so the banner does not linger;
        // a failure stays until the user retries or edits further.
        if ok {
            let snapshot = saveOutcome
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if saveOutcome == snapshot { saveOutcome = nil }
            }
        }
    }

    private func deleteSelected() {
        guard selection != nil else { return }
        activeDialog = .delete
    }

    private func performDelete() {
        guard let id = selection else { return }
        store.delete(id: id)
        performNew()
    }

    private func performRun() {
        // Capture the script by value so the Task always runs the one the user
        // launched, even if selection changes mid-run.
        let scriptToRun = editing
        let launchedID = editing.id
        let input = scriptToRun.feedsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        runningScriptID = launchedID
        result = nil
        runTask = Task { @MainActor in
            let outcome = await ScriptRunner.run(scriptToRun, input: input)
            // Discard stale results so output never renders under the wrong script
            // after the user switched selection while the run was in flight.
            guard launchedID == editing.id else {
                if runningScriptID == launchedID { runningScriptID = nil }
                return
            }
            result = outcome
            runningScriptID = nil
            runTask = nil
        }
    }

    private func stopRun() {
        // Cancelling trips ScriptRunner's cancellation handler, which terminates
        // the child; the Task then resumes with a result and surfaces it.
        runTask?.cancel()
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}