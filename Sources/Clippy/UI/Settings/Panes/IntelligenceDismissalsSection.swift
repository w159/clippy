import SwiftUI

/// Manages "never suggest" clips and apps excluded from suggestions. Shows counts only, never content.
struct IntelligenceDismissalsSection: View {
    @Environment(\.clippyTokens) private var tokens
    @Binding var notice: PaneNotice?
    @State private var neverCount = 0
    @State private var demotedCount = 0
    @State private var apps: [String] = []
    @State private var confirmRestore = false

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("Dismissed suggestions", footer: "Clips you marked \"never suggest\" and apps you excluded stay out of Smart Suggestions until restored.") {
            SettingsRow(title: "Never suggest", detail: Text("\(neverCount) clip\(neverCount == 1 ? "" : "s"); \(demotedCount) marked not relevant")) {
                Button("Restore All\u{2026}") { confirmRestore = true }
                    .disabled(neverCount + demotedCount + apps.count == 0)
            }
            Divider()
            if apps.isEmpty {
                SettingsRow(title: "Excluded apps", detail: Text("No apps excluded.")) { EmptyView() }
            } else {
                ForEach(apps, id: \.self) { bundleID in
                    SettingsRow(title: LocalizedStringKey(bundleID), detail: Text("Excluded from suggestions")) {
                        Button("Remove") { remove(bundleID) }
                            .accessibilityLabel("Stop excluding \(bundleID)")
                    }
                    Divider()
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Restore all dismissed suggestions?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore All", role: .destructive, action: restoreAll)
        } message: {
            Text("Every clip and app you dismissed becomes eligible for suggestions again.")
        }
    }

    private func reload() {
        let entries = SuggestionDismissals.shared.entries()
        neverCount = entries.filter { $0.kind == .never }.count
        demotedCount = entries.filter { $0.kind == .notRelevant }.count
        apps = SuggestionDismissals.shared.excludedApps()
    }

    private func remove(_ bundleID: String) {
        SuggestionDismissals.shared.includeApp(bundleID)
        reload()
    }

    private func restoreAll() {
        let store = SuggestionDismissals.shared
        for entry in store.entries() { store.restore(contentKey: entry.contentKey) }
        for app in store.excludedApps() { store.includeApp(app) }
        reload()
        notice = .success("All dismissed suggestions restored.")
    }
}
