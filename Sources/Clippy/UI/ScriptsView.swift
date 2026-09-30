import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manage, edit and run stored scripts. List on the left (multi-select for
/// batch runs), the code editor filling the height on the right, and a
/// resizable output drawer under it. There is one scroller per region and no
/// page-level scroller, so Save, Run and the output are always on screen.
///
/// Run-confirmation policy: Settings asks before every run (editing happens
/// here, so a per-run prompt is acceptable); the panel asks once per session
/// unless the script sets `confirmBeforeRun`.
struct ScriptsView: View {
    @ObservedObject var store = ScriptStore.shared
    @ObservedObject var center = ScriptRunCenter.shared
    @ObservedObject var settings = AppSettings.shared
    var tokens: ThemeTokens { settings.theme }

    /// The script in the editor. Nil means nothing is open. It may be a draft
    /// (an id the store does not have yet).
    @State var editing: Script?
    @State var batchSelection = ScriptBatchSelection()
    var selection: Set<UUID> { batchSelection.ids }
    @State var searchQuery = ""
    @State var draggingOverScriptID: String?
    @State var pendingNav: PendingNav?
    @State var activeDialog: Dialog?
    @State var saveOutcome: SaveOutcome?
    @State var showOptions = false
    @State var preflight: String?
    @State var notice: String?
    @State var drawerTab: DrawerTab = .output
    @State var historyDetail: ScriptRunRecord?
    @State var showRunHistory = false
    @State var showBadgeLegend = false

    /// Below this width the list collapses into a picker above the editor.
    static let splitBreakpoint: CGFloat = 520

    enum PendingNav: Equatable { case open(UUID?), newScript }
    enum SaveOutcome: Equatable { case saved, failed }
    enum Dialog: Equatable { case run, discard, delete, batch }
    enum DrawerTab: Hashable { case output, history }

    struct PreflightKey: Hashable {
        var interpreter: ScriptInterpreter
        var custom: String
        var directory: String
        var id: UUID?
    }

    // MARK: - Derived state

    var isDraft: Bool {
        guard let editing else { return false }
        return store.script(id: editing.id) == nil
    }

    /// True when the editor holds unsaved changes. Covers every editable field.
    var isDirty: Bool {
        guard let editing else { return false }
        if let stored = store.script(id: editing.id) { return editing.hasEditableChanges(comparedTo: stored) }
        return editing.isDirtyDraft
    }

    var filteredScripts: [Script] { store.search(searchQuery) }

    var currentRun: ScriptRun? { editing.flatMap { center.run(for: $0.id) } }

    var selectedScripts: [Script] { batchSelection.ordered(in: filteredScripts.map(\.id)).compactMap { store.script(id: $0) } }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.splitBreakpoint {
                HSplitView {
                    listPane
                        .frame(minWidth: 140, idealWidth: 190, maxWidth: 260)
                    detailPane
                        .frame(minWidth: 240, maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    compactListBar
                    Divider()
                    detailPane
                }
            }
        }
        .clippyDesignSystem()
        .onAppear {
            if editing == nil, let first = store.scripts.first { performOpen(first.id) }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(
            get: { activeDialog != nil },
            set: { if !$0 { activeDialog = nil } }
        ), titleVisibility: .visible) {
            dialogButtons
        } message: {
            Text(dialogMessage)
        }
    }

    // MARK: - Dialogs

    var dialogTitle: String {
        switch activeDialog {
        case .run: return "Run \"\(displayName(editing?.name))\"?"
        case .discard: return "Discard unsaved changes?"
        case .delete: return "Delete \"\(displayName(editing?.name))\"?"
        case .batch: return "Run \(selectedScripts.count) scripts in order?"
        case nil: return ""
        }
    }

    var dialogMessage: String {
        switch activeDialog {
        case .run, .batch: return "Runs scripts using their saved sandbox policies. Unsandboxed scripts can use your Mac permissions."
        case .discard: return "Switching scripts will lose your edits to the current one."
        case .delete: return "This removes the script from your saved list. This cannot be undone."
        case nil: return ""
        }
    }

    @ViewBuilder var dialogButtons: some View {
        switch activeDialog {
        case .run:
            Button("Run", role: .destructive) { performRun(); activeDialog = nil }
        case .batch:
            Button("Run All", role: .destructive) {
                center.startBatch(selectedScripts)
                activeDialog = nil
            }
        case .discard:
            Button("Discard", role: .destructive) {
                if let nav = pendingNav {
                    switch nav {
                    case .open(let id): performOpen(id)
                    case .newScript: performNew()
                    }
                }
                pendingNav = nil
                activeDialog = nil
            }
        case .delete:
            Button("Delete", role: .destructive) { performDelete(); activeDialog = nil }
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) { pendingNav = nil; activeDialog = nil }
    }

    func displayName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Untitled" }
        return name
    }
}

// MARK: - Options popover

/// Per-script settings that do not belong in the main toolbar. Text-shaped
/// Arguments keep a draft string so typing a trailing space or a half-finished
/// quote is not "corrected" mid-keystroke.
struct ScriptOptionsForm: View {
    @Binding var script: Script
    @State private var argumentsText: String

    init(script: Binding<Script>) {
        _script = script
        _argumentsText = State(initialValue: ScriptArguments.join(script.wrappedValue.arguments))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Arguments") {
                TextField("e.g. --dry-run \"two words\"", text: $argumentsText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: argumentsText) { _, new in script.arguments = ScriptArguments.split(new) }
            }
            labeled("Working directory") {
                HStack {
                    TextField("Home folder", text: $script.workingDirectory).textFieldStyle(.roundedBorder)
                    Button("Choose...") { chooseFile(directories: true) { script.workingDirectory = $0 } }
                }
            }
            labeled("Interpreter path (optional)") {
                HStack {
                    TextField("Resolved from PATH", text: $script.customInterpreterPath).textFieldStyle(.roundedBorder)
                    Button("Choose...") { chooseFile(directories: false) { script.customInterpreterPath = $0 } }
                }
            }
            ScriptEnvironmentEditor(environment: $script.environment)
            labeled("Standard input (used when no clipboard text is fed)") {
                TextEditor(text: $script.stdinText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 48)
                    .border(Color.secondary.opacity(0.3))
            }
            Stepper(value: $script.timeoutSeconds, in: 0...3600, step: 5) {
                Text(script.timeoutSeconds == 0 ? "Timeout: none" : "Timeout: \(script.timeoutSeconds) s")
            }
            Divider()
            Toggle("Feed the clipboard text to the script (stdin and $CLIPPY_CLIP)", isOn: $script.feedsClipboard)
            Toggle("Put the output on the clipboard when it succeeds", isOn: $script.outputToClipboard)
            Toggle("Confirm before every run (also in the panel)", isOn: $script.confirmBeforeRun)
            ScriptSandboxControls(scriptID: script.id)
            Toggle("Enabled", isOn: $script.isEnabled)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseFile(directories: Bool, apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }
}


#Preview("Scripts") {
    ScriptsView()
        .frame(width: 900, height: 680)
}
