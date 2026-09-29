import SwiftUI

/// Sensitive-content overrides and the auto-clear delay. Counts only; clip text never appears here.
struct SecuritySensitiveSection: View {
    @Binding var notice: PaneNotice?
    @State private var overrideCount = 0
    @State private var loaded = false
    @State private var autoClear = CapturePreferences.sensitiveAutoClearSeconds
    @State private var deletesHistory = CapturePreferences.autoClearDeletesHistory
    @State private var confirmClear = false

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("Sensitive content", footer: "Passwords, keys and card numbers are detected automatically and shown masked. Overrides are clips you marked sensitive or not sensitive.") {
            SettingsRow(title: "Manual overrides", detail: Text(loaded ? "\(overrideCount) clip\(overrideCount == 1 ? "" : "s")" : "Counting\u{2026}")) {
                Button("Clear Overrides\u{2026}") { confirmClear = true }.disabled(overrideCount == 0)
            }
            Divider()
            SettingsRow(title: "Auto-clear sensitive clips", detail: Text(autoClear == 0 ? "Off" : "After \(autoClear) seconds")) {
                Stepper("Auto-clear sensitive clips", value: $autoClear, in: 0...600, step: 5).labelsHidden()
                    .onChange(of: autoClear) { _, value in CapturePreferences.sensitiveAutoClearSeconds = value }
            }
            Divider()
            SettingsRow(title: "Also delete from history", detail: Text("Otherwise the secret stays in history after the clipboard clears."), enabled: autoClear > 0) {
                Toggle("Also delete from history", isOn: $deletesHistory).labelsHidden()
                    .onChange(of: deletesHistory) { _, value in CapturePreferences.autoClearDeletesHistory = value }
            }
        }
        .task { await countOverrides() }
        .confirmationDialog("Clear all sensitive overrides?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Overrides", role: .destructive) { Task { await clearOverrides() } }
        } message: {
            Text("Clips fall back to automatic detection.")
        }
    }

    private func countOverrides() async {
        let count = await Task.detached { SensitiveOverrideScan.keys().count }.value
        overrideCount = count
        loaded = true
    }

    private func clearOverrides() async {
        let cleared = await Task.detached { () -> Int in
            let keys = SensitiveOverrideScan.keys()
            for key in keys { SensitiveFlagStore.current?.setOverride(key: key, isSensitive: nil) }
            return keys.count
        }.value
        AuditLog.shared.record(actor: "settings", action: "clear-sensitive-overrides", detail: "\(cleared) overrides cleared", clipIDs: [])
        overrideCount = 0
        notice = .success("Cleared \(cleared) override\(cleared == 1 ? "" : "s").")
    }
}

/// Finds content keys carrying a manual sensitive override. Runs off the main actor.
enum SensitiveOverrideScan {
    /// Keys of clips with an explicit override; empty when the store or database is unavailable.
    nonisolated static func keys() -> [String] {
        guard let store = SensitiveFlagStore.current, let clips = try? ClipDatabase.shared.allClips() else { return [] }
        return Set(clips.map(\.contentKey)).filter { store.entry(for: $0)?.userOverride != nil }
    }
}
