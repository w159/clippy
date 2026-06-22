import SwiftUI
import AppKit

/// The main-pane view shown when Scripts is selected in the side panel.
/// Lists every saved script with a Run button; shows inline output after each
/// run with stdout/stderr distinguished, exit code, and duration.
/// Respects feedsClipboard (stdin from current clipboard) and
/// outputToClipboard (writes stdout to pasteboard on success).
struct ScriptsPanelView: View {
    @ObservedObject var store: ClipStore
    let onOpenSettings: () -> Void

    @ObservedObject private var scriptStore = ScriptStore.shared
    @ObservedObject private var settings = AppSettings.shared

    /// Per-script run state, keyed by script UUID.
    @State private var runStates: [UUID: RunState] = [:]
    /// Scripts the user has already confirmed once this session. The panel is a
    /// quick-launch surface, so we only nag the first time a given script runs
    /// (see the run-confirmation policy documented on `Script`). Settings
    /// confirms every run; the panel confirms once per script.
    @State private var confirmedScripts: Set<UUID> = []
    /// Search filter for the script list (in-memory name contains). Scripts are
    /// a small set, so filtering live on every keystroke is cheaper than a timer.
    @State private var query = ""

    private var tokens: ThemeTokens { settings.theme }

    private var filteredScripts: [Script] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return scriptStore.scripts }
        return scriptStore.scripts.filter {
            $0.name.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        if scriptStore.scripts.isEmpty {
            emptyState
        } else {
            scriptList
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
            Text("No scripts yet")
                .font(PanelTypography.body(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
            Text("Add scripts in Settings to run them from here.")
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
                .multilineTextAlignment(.center)
            // Relabelled from "Open Settings > Scripts": onOpenSettings opens the
            // settings window generally and does not guarantee the Scripts tab,
            // so the chevron-suffixed label overpromised.
            Button("Open Settings") {
                onOpenSettings()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Script list

    private var scriptList: some View {
        VStack(spacing: 0) {
            manageHeader
            // Search field so a long script list can be narrowed by name.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.textSecondary)
                TextField("Search scripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(PanelTypography.metadata(settings))
                if !query.isEmpty {
                    Button {
                        query = ""
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
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filteredScripts.isEmpty {
                        Text("No scripts match \"\(query)\"")
                            .font(PanelTypography.metadata(settings))
                            .foregroundStyle(tokens.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    ForEach(filteredScripts) { script in
                        ScriptRowView(
                            script: script,
                            store: store,
                            runState: Binding(
                                get: { runStates[script.id] ?? .idle },
                                set: { runStates[script.id] = $0 }
                            ),
                            confirmedScripts: $confirmedScripts,
                            tokens: tokens,
                            settings: settings
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var manageHeader: some View {
        HStack {
            Text("SCRIPTS")
                .font(PanelTypography.micro(settings).weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(tokens.textSecondary)
            Spacer()
            Button("Manage...") {
                onOpenSettings()
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(tokens.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }
}

// MARK: - Per-script row

private struct ScriptRowView: View {
    let script: Script
    let store: ClipStore
    @Binding var runState: RunState
    @Binding var confirmedScripts: Set<UUID>
    let tokens: ThemeTokens
    let settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Handle to the in-flight run so the Stop button can cancel it. ScriptRunner
    /// owns the Process and terminates it on Task.cancel() (see ScriptRunner).
    @State private var runTask: Task<Void, Never>?
    /// Drives the first-run confirmation dialog (per-script, once per session).
    @State private var pendingRun = false
    /// Transient "Saved as clip" / "Could not save clip" feedback.
    @State private var saveStatus: String?

    private var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowHeader
            if isRunning {
                runningView
            } else if case .done(let result) = runState {
                outputView(result)
            }
        }
        .padding(10)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        // First-run confirmation: nags once per script, then runs directly.
        // Policy is documented on Script; Settings confirms every run instead.
        .confirmationDialog(
            "Run \"\(script.name.isEmpty ? "Untitled" : script.name)\"?",
            isPresented: $pendingRun,
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) { performRun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This executes code on your Mac with your user permissions. You will not be asked again for this script in this session.")
        }
    }

    // MARK: Header row

    private var rowHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(script.name.isEmpty ? "Untitled" : script.name)
                    .font(PanelTypography.body(settings).weight(.medium))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    interpreterBadge
                    if script.feedsClipboard {
                        flagBadge("arrow.up.to.line", "Reads clipboard")
                    }
                    if script.outputToClipboard {
                        flagBadge("arrow.down.to.line", "Writes to clipboard")
                    }
                    Spacer(minLength: 0)
                    Text(script.updatedAt, format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow))
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            Spacer(minLength: 8)
            runButton
        }
    }

    private var interpreterBadge: some View {
        Text(script.interpreter.displayName)
            .font(PanelTypography.micro(settings).weight(.medium))
            .foregroundStyle(tokens.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                tokens.accent.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }

    private func flagBadge(_ icon: String, _ help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tokens.textSecondary)
            .help(help)
    }

    // While running, the button becomes a Stop control (which cancels the run
    // via runTask). The running indicator below keeps the single spinner, so
    // we avoid the double-spinner the audit flagged here.
    private var runButton: some View {
        Button {
            isRunning ? stop() : run()
        } label: {
            Group {
                if isRunning {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(isRunning ? "Stop script" : "Run script")
        .accessibilityLabel(isRunning ? "Stop \(script.name)" : "Run \(script.name)")
    }

    // MARK: Running indicator

    private var runningView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Running...")
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Output view

    @ViewBuilder
    private func outputView(_ result: ScriptResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status line
            HStack(spacing: 6) {
                Image(systemName: result.timedOut
                    ? "exclamationmark.clock.fill"
                    : (result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(result.succeeded ? tokens.success : tokens.danger)
                    .font(.system(size: 12))
                    // Pop the status glyph in when a run finishes (success or fail).
                    .symbolEffect(.bounce, value: reduceMotion ? false : result.succeeded)
                Text(statusLabel(result))
                    .font(PanelTypography.metadata(settings).weight(.medium))
                    .foregroundStyle(result.succeeded ? tokens.success : tokens.danger)
                Spacer()
                Text("\(result.durationMs) ms")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .monospacedDigit()
            }

            // Truncation banner: the runner hit the 5 MB stream ceiling and killed
            // the child. Distinct from the display cap applied per block below.
            if result.truncated {
                Label("Output truncated: hit the capture ceiling", systemImage: "scissors")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.danger)
            }

            // stdout (only shown when non-empty)
            if !result.stdout.isEmpty {
                outputBlock(result.stdout, label: "stdout", isError: false)
            }

            // stderr (only shown when non-empty, clearly labeled in red)
            if !result.stderr.isEmpty {
                outputBlock(result.stderr, label: "stderr", isError: true)
            }

            if result.stdout.isEmpty && result.stderr.isEmpty {
                Text("(no output)")
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .italic()
            }

            outputActions(result)
        }
        .padding(8)
        .background(tokens.scrollBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func outputBlock(_ text: String, label: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(PanelTypography.micro(settings).weight(.semibold))
                .foregroundStyle(isError ? tokens.danger.opacity(0.8) : tokens.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                // Display cap with a "(showing first 2000 of N characters)" note when
                // the stream is longer than the cap. Kept in sync with ScriptsView
                // via ScriptResult.displayCap / displayCapped.
                Text(ScriptResult.displayCapped(text.trimmingCharacters(in: .newlines)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
    }

    @ViewBuilder
    private func outputActions(_ result: ScriptResult) -> some View {
        let hasStdout = !result.stdout.isEmpty
        let hasStderr = !result.stderr.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if hasStdout {
                    Button("Copy output") {
                        copyToPasteboard(result.stdout)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    Button("Save as clip") {
                        saveAsClip(result.stdout)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                // stderr was visible but not copyable from the panel; offer it
                // whenever stderr is non-empty so errors can be shared/pasted.
                if hasStderr {
                    Button("Copy stderr") {
                        copyToPasteboard(result.stderr)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Dismiss") {
                    runState = .idle
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(tokens.textSecondary)
            }
            // Transient save-as-clip feedback (mirrors the OCR status pattern in
            // ClipEditorView): success/failure message that auto-clears.
            if let saveStatus {
                Text(saveStatus)
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(saveStatus.hasPrefix("Saved") ? tokens.success : tokens.danger)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Status label

    private func statusLabel(_ result: ScriptResult) -> String {
        if result.timedOut { return "Timed out" }
        return result.exitCode == 0 ? "Succeeded" : "Failed (exit \(result.exitCode))"
    }

    // MARK: Run action

    private func run() {
        // First-run gate: nag once per script, then run directly (see Script).
        guard confirmedScripts.contains(script.id) else {
            pendingRun = true
            return
        }
        performRun()
    }

    private func performRun() {
        confirmedScripts.insert(script.id)
        let input = script.feedsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        runState = .running
        runTask = Task { @MainActor in
            let result = await ScriptRunner.run(script, input: input)
            // Honor outputToClipboard before surfacing the result in the UI.
            if script.outputToClipboard, result.succeeded, !result.stdout.isEmpty {
                copyToPasteboard(result.stdout)
            }
            runState = .done(result)
            runTask = nil
        }
    }

    private func stop() {
        // Cancelling the Task trips ScriptRunner's cancellation handler, which
        // terminates the child promptly; the Task then resumes with a result
        // (stderr "Cancelled") and surfaces it via runState.
        runTask?.cancel()
    }

    // MARK: Save as clip

    private func saveAsClip(_ text: String) {
        // saveScriptOutput returns Bool; surface both outcomes instead of
        // discarding it, so a failed insert is not silently lost.
        let ok = store.saveScriptOutput(text)
        let message = ok ? "Saved as clip" : "Could not save clip"
        saveStatus = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if saveStatus == message { saveStatus = nil }
        }
    }

    // MARK: Pasteboard helper

    /// Replaces the pasteboard contents with `string`. Called from both the
    /// "Copy output" / "Copy stderr" buttons and the outputToClipboard auto-copy.
    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Run state

/// The three states a per-script row can be in.
enum RunState: Equatable {
    case idle
    case running
    case done(ScriptResult)
}