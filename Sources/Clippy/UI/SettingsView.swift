import AppKit
import SwiftUI

/// The settings window: a sidebar of panes with search (SET-09), or a pushing list when
/// the window is compact. Each pane footer offers reset, export and import.
struct SettingsView: View {
    private let settings = AppSettings.shared
    @State private var model: SettingsShellModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hostWindow: NSWindow?
    @State private var highlightedHit = 0
    @State private var searchFocusToken = 0

    /// `model` is injectable so tests can assert on selection and search state.
    init(model: SettingsShellModel? = nil) {
        _model = State(initialValue: model ?? SettingsShellModel())
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width < SettingsShellModel.compactBreakpoint { compactLayout } else { regularLayout }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .clippyDesignSystem()
        .tint(ClippyTokens.resolve(from: settings.theme).accentInk)
        .toggleStyle(AccentToggleStyle())
        .environment(\.settingsFlashRow, model.flashRow)
        .background(WindowAppearanceApplier(appearance: Theme.nsAppearance(settings)))
        .background(SettingsWindowFrameSaver(name: "ClippySettingsWindow.v2"))
        .background(SettingsWindowReader { hostWindow = $0 })
        .background(PaneShortcutButtons { paneSelection.wrappedValue = $0 })
        // Inside the sidebar search field, Esc is handled by the field's delegate, which clears the
        // query and then closes the window; `.onExitCommand` covers Esc from other focused controls.
        .onExitCommand { closeOrClearSearch() }
        .task { await focusSearchField() }
        .confirmationDialog("Reset \(model.selection.title) settings?", isPresented: $model.showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Reset this pane", role: .destructive) { model.resetSelectedPane() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores this pane's settings to their defaults. API keys and clip history are not affected.")
        }
        .sheet(item: $model.pendingImport) { pending in
            ImportSummarySheet(pending: pending, confirmed: $model.confirmedKeys, onApply: { model.confirmImport() }, onCancel: { model.pendingImport = nil })
        }
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        NavigationSplitView {
            paneList
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            if model.compactShowsPane {
                detail
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { model.compactShowsPane = false } label: { Label("Settings", systemImage: "chevron.left") }
                                .keyboardShortcut("[", modifiers: .command)
                        }
                    }
            } else {
                paneList.navigationTitle("Settings")
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var paneList: some View {
        // The field sits beside the list, not inside it: swapping the pane list for the results list
        // while typing must not rebuild the field, or it loses focus after the first character.
        VStack(spacing: 0) {
            SettingsSearchField(text: $model.query, focusToken: searchFocusToken, onMove: handleMove,
                                onSubmit: openHighlightedHit, onCancel: closeOrClearSearch)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            paneListBody
        }
        .onChange(of: model.query) { _, _ in highlightedHit = 0 }
    }

    @ViewBuilder
    private var paneListBody: some View {
        Group {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollViewReader { proxy in
                    List {
                        ForEach(SettingsPaneSection.all) { section in
                            Section(section.title) {
                                ForEach(section.panes) { pane in
                                    PaneRow(pane: pane, isSelected: pane == model.selection) {
                                        paneSelection.wrappedValue = pane
                                        searchFocusToken += 1
                                    }
                                    .id(pane.id)
                                }
                            }
                        }
                    }
                    // No `selection:` binding: the system sidebar highlight is blue and ignores tint, so
                    // rows draw `tokens.selection` themselves. The search field above owns the keyboard
                    // and moves the selection (Up/Down) or the search highlight (Return opens it).
                    .onAppear { proxy.scrollTo(model.selection.id) }
                    .onChange(of: model.selection) { _, pane in proxy.scrollTo(pane.id) }
                }
            } else {
                resultsList
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .controlSize(.small)
    }

    private func closeOrClearSearch() {
        if model.query.isEmpty { hostWindow?.close() } else { model.query = "" }
    }

    /// Puts keyboard focus on the search field once the window is up, so arrows move panes at once.
    private func focusSearchField() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        searchFocusToken += 1
    }

    /// Up/Down move the pane selection, or the highlighted hit while a search is active.
    private func handleMove(_ direction: MoveCommandDirection) {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            moveSelection(direction)
        } else {
            moveHighlight(direction)
        }
    }

    private func moveHighlight(_ direction: MoveCommandDirection) {
        guard !model.query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let last = model.results.count - 1
        switch direction {
        case .up: highlightedHit = max(highlightedHit - 1, 0)
        case .down: highlightedHit = min(highlightedHit + 1, max(last, 0))
        default: break
        }
    }

    private func openHighlightedHit() {
        let hits = model.results
        guard hits.indices.contains(highlightedHit) else { return }
        model.jump(to: hits[highlightedHit])
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let panes = SettingsPaneSection.all.flatMap(\.panes)
        guard let index = panes.firstIndex(of: model.selection) else { return }
        switch direction {
        case .up where index > 0: paneSelection.wrappedValue = panes[index - 1]
        case .down where index < panes.count - 1: paneSelection.wrappedValue = panes[index + 1]
        default: break
        }
    }

    private var paneSelection: Binding<SettingsPaneID?> {
        Binding(get: { model.selection }, set: { newValue in
            guard let newValue else { return }
            model.selection = newValue
            model.compactShowsPane = true
        })
    }

    @ViewBuilder
    private var resultsList: some View {
        let hits = model.results
        if hits.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else {
            List(hits) { hit in
                SearchHitRow(hit: hit, isHighlighted: hit.id == hits[safe: highlightedHit]?.id) { model.jump(to: hit) }
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        // Scripts is a full editor (its own list, toolbar and output drawer): give it the whole
        // detail area instead of the title bar, footer and scroller that would clip it.
        if model.selection == .scripts {
            return AnyView(SettingsPaneRegistry.view(for: .scripts).background(settings.theme.panel).navigationTitle("Scripts"))
        }
        return AnyView(paneDetail)
    }

    private var paneDetail: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                SettingsPaneRegistry.view(for: model.selection)
                    .buttonStyle(.bordered)
                    .task(id: model.selection) { await clearInitialTextFocus() }
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: model.selection.usesFormColumn ? SettingsPaneID.columnMaxWidth : .infinity, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: model.jumpToken) { _, _ in
                        if let target = model.flashRow { withAnimation(ClippyMotion.animation(.standard, reduce: reduceMotion)) { proxy.scrollTo(target, anchor: .center) } }
                    }
            }
            Divider()
            footer
        }
        .background(settings.theme.panel)
        // The pane title lives in the window's title bar instead of a second header row, which
        // gives the content the vertical space the old row and dead title-bar band wasted.
        .navigationTitle(model.selection.title)
    }

    /// A pane's first text field would otherwise grab focus with its text selected when the pane
    /// opens. Once the pane has laid out, focus moves back to the sidebar search field, unless the
    /// search field already holds focus.
    @MainActor
    private func clearInitialTextFocus() async {
        try? await Task.sleep(for: .milliseconds(60))
        guard model.query.isEmpty, let window = hostWindow ?? NSApp.keyWindow else { return }
        // Swapping panes can leave the window itself as first responder when the focused view goes away.
        guard window.firstResponder is NSText || window.firstResponder === window else { return }
        if let editor = window.firstResponder as? NSTextView,
           (editor.delegate as? NSView)?.identifier == SettingsSearchField.identifier { return }
        searchFocusToken += 1
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Reset this pane") { model.showResetConfirmation = true }
                .disabled(!model.selection.isResettable)
            Button("Export\u{2026}") { model.exportPreferences() }
            Button("Import\u{2026}") { model.beginImport() }
            Spacer(minLength: 8)
            if let status = model.status { StatusOutcomeLabel(outcome: status, successColor: settings.theme.success) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 22).padding(.vertical, 8)
    }
}

/// One search result: opens its pane; the keyboard-highlighted row is tinted.
private struct SearchHitRow: View {
    @Environment(\.clippyTokens) private var tokens
    let hit: SettingsSearchHit
    let isHighlighted: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.entry.title)
                Text(SettingsPaneID(rawValue: hit.entry.pane)?.title ?? hit.entry.pane)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .background(isHighlighted ? tokens.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(FocusRingButtonStyle())
    }
}

/// Hidden buttons that give Cmd-1 through Cmd-9 to the first nine panes, in sidebar order.
private struct PaneShortcutButtons: View {
    let select: (SettingsPaneID) -> Void

    var body: some View {
        let panes = Array(SettingsPaneSection.all.flatMap(\.panes).prefix(9))
        ZStack {
            ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                Button(pane.title) { select(pane) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Hands the hosting window to `onWindow` (used to close it on Esc).
private struct SettingsWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in onWindow(view.window) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Sidebar row: title in the primary text token so labels stay legible (>= 4.5:1) on every
/// theme preset instead of the dimmed system sidebar secondary style.
private struct PaneRow: View {
    @Environment(\.clippyTokens) private var tokens
    @AppStorage(SettingsSeenPanes.defaultsKey) private var seenPanes = ""
    let pane: SettingsPaneID
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                HStack(spacing: tokens.metrics.space.two) {
                    Text(pane.title).foregroundStyle(tokens.textPrimary)
                    if SettingsSeenPanes.showsNewPill(pane, seen: seenPanes) { NewPill() }
                }
            } icon: {
                Image(systemName: pane.icon).foregroundStyle(tokens.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous)
                .fill(isSelected ? tokens.selection : Color.clear)
                .padding(.horizontal, 6)
        )
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small "NEW" marker on recently added panes.
private struct NewPill: View {
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tokens.accentText)
            .padding(.horizontal, tokens.metrics.space.one + 1).padding(.vertical, 1)
            .background(tokens.selection, in: Capsule())
            .accessibilityLabel("New")
    }
}

/// Diff summary shown before an import is applied.
private struct ImportSummarySheet: View {
    let pending: PendingSettingsImport
    @Binding var confirmed: Set<String>
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import preferences").font(.headline)
            Text("\(pending.fileName): \(pending.plan.summary)").font(.callout)
            List(pending.plan.changes, id: \.key) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.key).font(.system(.caption, design: .monospaced))
                    Text("\(describe(change.old)) \u{2192} \(describe(change.new))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 140)
            if !pending.plan.requiresConfirmation.isEmpty {
                Text("Security-relevant settings (off unless ticked)").font(.subheadline.weight(.semibold))
                ForEach(pending.plan.requiresConfirmation, id: \.key) { change in
                    Toggle(isOn: confirmBinding(change.key)) {
                        Text("\(change.key): \(describe(change.old)) \u{2192} \(describe(change.new))")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply", action: onApply).buttonStyle(.accent).keyboardShortcut(.defaultAction)
                    .disabled(pending.plan.changes.isEmpty && confirmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func confirmBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { confirmed.contains(key) }, set: { on in
            if on { confirmed.insert(key) } else { confirmed.remove(key) }
        })
    }

    private func describe(_ value: PreferenceValue?) -> String {
        guard let value else { return "default" }
        switch value {
        case .bool(let flag): return flag ? "on" : "off"
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .string(let text): return text.isEmpty ? "(empty)" : text
        case .strings(let list): return CountCopy.listSummary(list.count)
        case .map(let map): return "\(map.count) entr\(map.count == 1 ? "y" : "ies")"
        }
    }
}

/// Persists and restores the hosting window's frame under `name`.
struct SettingsWindowFrameSaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let autosaveName = name
        Task { @MainActor in
            guard let window = view.window, window.frameAutosaveName != autosaveName else { return }
            window.setFrameAutosaveName(autosaveName)
        }
    }
}

extension Bundle {
    /// CFBundleShortVersionString, or a dev fallback when running unbundled.
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// CFBundleVersion, or a dev fallback.
    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
    }
}

#Preview("Settings window") { SettingsView().frame(width: 780, height: 580) }
