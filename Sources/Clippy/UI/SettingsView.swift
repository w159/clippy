import AppKit
import SwiftUI

/// The settings window: a sidebar of panes with search (SET-09), or a pushing list when
/// the window is compact. Each pane footer offers reset, export and import.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model = SettingsShellModel()

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width < SettingsShellModel.compactBreakpoint { compactLayout } else { regularLayout }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .clippyDesignSystem()
        .tint(settings.theme.accent)
        .environment(\.settingsFlashRow, model.flashRow)
        .background(WindowAppearanceApplier(appearance: Theme.nsAppearance(settings)))
        .background(SettingsWindowFrameSaver(name: "ClippySettingsWindow.v2"))
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
        Group {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollViewReader { proxy in
                    List(selection: paneSelection) {
                        ForEach(SettingsPaneSection.all) { section in
                            Section(section.title) {
                                ForEach(section.panes) { pane in
                                    PaneRow(pane: pane)
                                        .tag(pane)
                                        .id(pane.id)
                                        .accessibilityLabel(pane.title)
                                }
                            }
                        }
                    }
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
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search settings")
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
                Button { model.jump(to: hit) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.entry.title)
                        Text(SettingsPaneID(rawValue: hit.entry.pane)?.title ?? hit.entry.pane)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
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
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: model.selection.usesFormColumn ? SettingsPaneID.columnMaxWidth : .infinity, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: model.jumpToken) { _, _ in
                        if let target = model.flashRow { withAnimation { proxy.scrollTo(target, anchor: .center) } }
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

/// Sidebar row: title in the primary text token so labels stay legible (>= 4.5:1) on every
/// theme preset instead of the dimmed system sidebar secondary style.
private struct PaneRow: View {
    @Environment(\.clippyTokens) private var tokens
    let pane: SettingsPaneID

    var body: some View {
        Label {
            HStack(spacing: tokens.metrics.space.two) {
                Text(pane.title).foregroundStyle(tokens.textPrimary)
                if pane.isNew { NewPill() }
            }
        } icon: {
            Image(systemName: pane.icon).foregroundStyle(tokens.textSecondary)
        }
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
                Button("Apply", action: onApply).keyboardShortcut(.defaultAction)
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
        case .strings(let list): return "\(list.count) item(s)"
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
