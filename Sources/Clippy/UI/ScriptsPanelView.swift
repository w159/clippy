import SwiftUI
import AppKit

/// The main-pane view shown when Scripts is selected in the side panel.
/// Lists every saved script with a Run button; run state and output come from
/// the shared `ScriptRunCenter` and render through `ScriptRunResultView`, the
/// same component Settings uses. Respects feedsClipboard (stdin from the
/// current clipboard) and outputToClipboard (applied by the run center).
///
/// Run-confirmation policy: the panel is a quick-launch surface, so it asks once
/// per script per session, or on every run when the script sets
/// `confirmBeforeRun`. Settings confirms every run.
struct ScriptsPanelView: View {
    @ObservedObject var store: ClipStore
    let onOpenSettings: () -> Void

    @ObservedObject private var scriptStore = ScriptStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var center = ScriptRunCenter.shared

    /// Scripts the user has already confirmed once this session.
    @State private var confirmedScripts: Set<UUID> = []
    @State private var query = ""
    @State private var showLegend = false

    private var tokens: ThemeTokens { settings.theme }

    /// Name or body matches, so a snippet can be found by what it does.
    private var filteredScripts: [Script] { scriptStore.search(query) }

    var body: some View {
        Group {
        if scriptStore.scripts.isEmpty {
            emptyState
        } else {
            scriptList
        }
        }
        .clippyDesignSystem()
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
            Button("Open Settings") { onOpenSettings() }
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.textSecondary)
                TextField("Search names and script bodies", text: $query)
                    .textFieldStyle(.plain)
                    .font(PanelTypography.metadata(settings))
                if !query.isEmpty {
                    Button { query = "" } label: {
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
                        ScriptRowView(script: script, store: store, center: center,
                                      confirmedScripts: $confirmedScripts,
                                      tokens: tokens, settings: settings)
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
            Button { showLegend.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help("What the badges mean")
            .accessibilityLabel("Badge legend")
            .popover(isPresented: $showLegend, arrowEdge: .bottom) { ScriptBadgeLegendView() }
            Spacer()
            Button("Manage...") { onOpenSettings() }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(tokens.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }
}

// MARK: - Badges

/// The badges a script row can show, with one explanation shared by the
/// tooltips, the accessibility labels and the legend popover.
enum ScriptBadge: CaseIterable {
    case readsClipboard, writesClipboard, disabled, confirms

    var icon: String {
        switch self {
        case .readsClipboard: return "arrow.up.to.line"
        case .writesClipboard: return "arrow.down.to.line"
        case .disabled: return "exclamationmark.shield"
        case .confirms: return "hand.raised"
        }
    }

    var title: String {
        switch self {
        case .readsClipboard: return "Reads clipboard"
        case .writesClipboard: return "Writes to clipboard"
        case .disabled: return "Disabled"
        case .confirms: return "Confirms every run"
        }
    }

    var detail: String {
        switch self {
        case .readsClipboard: return "Receives the current clipboard text on stdin and in $CLIPPY_CLIP."
        case .writesClipboard: return "Puts its output on the clipboard when it succeeds."
        case .disabled: return "Cannot run until you review and enable it in Settings > Scripts."
        case .confirms: return "Asks before every run, not just the first."
        }
    }

    func applies(to script: Script) -> Bool {
        switch self {
        case .readsClipboard: return script.feedsClipboard
        case .writesClipboard: return script.outputToClipboard
        case .disabled: return !script.isEnabled
        case .confirms: return script.confirmBeforeRun
        }
    }
}

// MARK: - Per-script row

private struct ScriptRowView: View {
    let script: Script
    let store: ClipStore
    @ObservedObject var center: ScriptRunCenter
    @Binding var confirmedScripts: Set<UUID>
    let tokens: ThemeTokens
    let settings: AppSettings

    @State private var pendingRun = false

    private var run: ScriptRun? { center.run(for: script.id) }
    private var isRunning: Bool { run?.isRunning ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowHeader
            if let run {
                ScriptRunResultView(run: run, layout: .compact,
                                    saveClip: { store.saveScriptOutput($0) },
                                    onDismiss: { center.dismiss(script.id) })
            }
        }
        .padding(10)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        .confirmationDialog(
            "Run \"\(script.name.isEmpty ? "Untitled" : script.name)\"?",
            isPresented: $pendingRun,
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) { performRun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(script.confirmBeforeRun
                 ? "This runs with the script's saved sandbox policy. It asks before every run."
                 : "This runs with the script's saved sandbox policy. You will not be asked again for this script in this session.")
        }
    }

    private var rowHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(script.name.isEmpty ? "Untitled" : script.name)
                    .font(PanelTypography.body(settings).weight(.medium))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(script.interpreter.displayName)
                        .font(PanelTypography.micro(settings).weight(.medium))
                        .foregroundStyle(tokens.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(tokens.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    ForEach(ScriptBadge.allCases.filter { $0.applies(to: script) }, id: \.title) { badge in
                        Image(systemName: badge.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tokens.textSecondary)
                            .help("\(badge.title). \(badge.detail)")
                            .accessibilityLabel(badge.title)
                    }
                    Spacer(minLength: 0)
                    Text(RelativeTime.string(for: script.updatedAt))
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            Spacer(minLength: 8)
            runButton
        }
    }

    private var runButton: some View {
        Button { isRunning ? run?.cancel() : attemptRun() } label: {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!script.isEnabled && !isRunning)
        .help(script.isEnabled
              ? (isRunning ? "Stop script" : "Run script")
              : "Disabled. Enable it in Settings > Scripts.")
        .accessibilityLabel(isRunning ? "Stop \(script.name)" : "Run \(script.name)")
    }

    /// Confirmation gate: always for `confirmBeforeRun`, else once per session.
    private func attemptRun() {
        if script.confirmBeforeRun || !confirmedScripts.contains(script.id) {
            pendingRun = true
            return
        }
        performRun()
    }

    private func performRun() {
        confirmedScripts.insert(script.id)
        center.start(script, sandbox: ScriptSandboxPolicy().sandbox(for: script.id))
    }
}

#Preview("Scripts panel") {
    ScriptsPanelPreviewHost()
        .frame(width: 360, height: 480)
}

private struct ScriptsPanelPreviewHost: View {
    @State private var store: ClipStore?

    var body: some View {
        Group {
            if let store {
                ScriptsPanelView(store: store, onOpenSettings: {})
            } else {
                ProgressView()
            }
        }
        .task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-scripts-preview", isDirectory: true)
            store = (try? ClipDatabase(databaseURL: root.appendingPathComponent("p.sqlite"),
                                       mediaDirectory: root.appendingPathComponent("media", isDirectory: true)))
                .map { ClipStore(database: $0, pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippyScriptsPreview"))) }
        }
    }
}
