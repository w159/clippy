import AppKit
import SwiftUI
import UniformTypeIdentifiers

// State and actions behind the settings window: selection, search, pane reset,
// preferences export/import (SET-09). SwiftUI-free logic lives in the pure types.

/// A validated import waiting for the user's confirmation.
struct PendingSettingsImport: Identifiable {
    let id = UUID()
    let plan: SettingsImportPlan
    let fileName: String
}

@MainActor
final class SettingsShellModel: ObservableObject {
    /// Below this width the window shows a list that pushes panes.
    static let compactBreakpoint: CGFloat = 560

    @Published var selection: SettingsPaneID
    @Published var query = ""
    @Published private(set) var flashRow: String?
    @Published private(set) var jumpToken = UUID()
    @Published var compactShowsPane = false
    @Published var showResetConfirmation = false
    @Published var pendingImport: PendingSettingsImport?
    @Published private(set) var status: StatusOutcome?
    /// Security-relevant keys the user explicitly ticked in the import sheet.
    @Published var confirmedKeys: Set<String> = []

    private let settings: AppSettings
    private let porter = SettingsPreferencesPorter(knownKeys: SettingsPaneID.allExportableKeys)
    private var flashTask: Task<Void, Never>?

    init(settings: AppSettings = .shared) {
        self.settings = settings
        let requested = ProcessInfo.processInfo.environment["CLIPPY_SETTINGS_SECTION"] ?? ""
        selection = SettingsPaneID(rawValue: requested) ?? .general
        query = ProcessInfo.processInfo.environment["CLIPPY_SETTINGS_QUERY"] ?? ""
    }

    /// Ranked search results for the current query.
    var results: [SettingsSearchHit] { SettingsSearchIndex.search(query, in: SettingsSearchCatalog.entries) }

    /// Opens the pane containing `hit`, scrolls to the row and flashes it.
    func jump(to hit: SettingsSearchHit) {
        guard let pane = SettingsPaneID(rawValue: hit.entry.pane) else { return }
        selection = pane
        compactShowsPane = true
        query = ""
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.jumpToken = UUID()
            self?.flashRow = hit.entry.id
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.flashRow = nil
        }
    }

    /// Resets the selected pane's keys to defaults (managed keys are skipped).
    func resetSelectedPane() {
        settings.resetKeys(selection.resetKeys)
        status = StatusOutcome(succeeded: true, message: "\(selection.title) settings were reset.")
    }

    /// Writes the exportable preferences to a user-chosen JSON file.
    func exportPreferences() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clippy-preferences.json"
        panel.message = "API keys and other secrets are never exported."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try porter.export(from: settings.defaults).write(to: url, options: .atomic)
            status = StatusOutcome(succeeded: true, message: "Exported preferences to \(url.lastPathComponent).")
        } catch {
            status = StatusOutcome(succeeded: false, message: "Export failed: \(error.localizedDescription)")
        }
    }

    /// Reads and validates a preferences file, then asks for confirmation.
    func beginImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let plan = try porter.plan(importing: data, against: settings.defaults)
            confirmedKeys = []
            pendingImport = PendingSettingsImport(plan: plan, fileName: url.lastPathComponent)
        } catch {
            status = StatusOutcome(succeeded: false, message: "Import failed: \(error.localizedDescription)")
        }
    }

    /// Applies the confirmed import.
    func confirmImport() {
        guard let pending = pendingImport else { return }
        porter.apply(pending.plan, to: settings.defaults, confirmed: confirmedKeys)
        settings.reloadFromDefaults()
        AIProviderStore.shared.reloadFromDefaults()
        let count = pending.plan.changes.count + pending.plan.requiresConfirmation.filter { confirmedKeys.contains($0.key) }.count
        status = StatusOutcome(succeeded: true, message: "Imported \(count) setting(s) from \(pending.fileName).")
        pendingImport = nil
    }
}
