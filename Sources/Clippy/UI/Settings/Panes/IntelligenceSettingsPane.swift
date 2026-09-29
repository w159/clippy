import AppKit
import SwiftUI

/// Smart Suggestions settings: behavior, Accessibility, on-device model, dismissals, diagnostics, cache.
struct IntelligenceSettingsPane: View {
    @Environment(\.clippyTokens) private var tokens
    @ObservedObject private var settings = AppSettings.shared
    @State private var notice: PaneNotice?
    @State private var accessibilityTrusted = CaretLocator.isTrusted
    @State private var useFoundationModels = SuggestionTuning.useFoundationModels
    @State private var modelStatus = FoundationModelsAvailability.current()
    @State private var cacheBytes: Int64 = IntelligenceSettingsPane.cacheFileBytes()
    @State private var confirmClearCache = false

    /// Creates the pane.
    init() {}

    var body: some View {
        PaneScroll(title: "Suggestions", notice: $notice) {
            behaviorSection
            accessibilitySection
            modelSection
            IntelligenceDismissalsSection(notice: $notice)
            IntelligenceDiagnosticsSection()
            cacheSection
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .confirmationDialog("Clear the suggestion cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                SuggestionEngine.shared.clearCache()
                cacheBytes = Self.cacheFileBytes()
                notice = .success("Suggestion cache cleared.")
            }
        } message: {
            Text("Suggestion vectors are rebuilt on this Mac as you use the panel.")
        }
    }

    private static let behaviorNote = "Clippy reads the app you were just using (name, window title and text near your cursor) "
        + "and ranks history by relevance, on this Mac only. Screen text stays in memory and is never saved or sent anywhere."

    private var behaviorSection: some View {
        PaneSection("Smart Suggestions", footer: Self.behaviorNote) {
            SettingsRow(title: "Smart Suggestions", enabled: !AppSettings.isForced(AppSettings.Keys.suggestionsEnabled)) {
                Toggle("Smart Suggestions", isOn: $settings.suggestionsEnabled).labelsHidden()
            }
            Divider()
            SettingsRow(title: "Use text from the focused field", detail: Text("Off: only the app name and window title are used."),
                        enabled: settings.suggestionsEnabled && !AppSettings.isForced(AppSettings.Keys.suggestionsUseWindowText)) {
                Toggle("Use text from the focused field", isOn: $settings.suggestionsUseWindowText).labelsHidden()
            }
            Divider()
            SettingsRow(title: "Suggestions shown", detail: Text("\(settings.suggestionsLimit)"), enabled: settings.suggestionsEnabled) {
                Stepper("Suggestions shown", value: $settings.suggestionsLimit, in: 3...20).labelsHidden()
            }
            Divider()
            SettingsRow(title: "Open Suggestions with the panel", enabled: settings.suggestionsEnabled) {
                Toggle("Open Suggestions with the panel", isOn: $settings.suggestionsAutoOpen).labelsHidden()
            }
        }
    }

    private var accessibilitySection: some View {
        PaneSection("Accessibility", footer: "Apps under Capture \u{203A} Ignored apps are never read for suggestions, and password fields are always skipped.") {
            SettingsRow(title: accessibilityTrusted ? "Accessibility access granted" : "Accessibility access needed",
                        detail: accessibilityTrusted ? nil : Text("Required to read the frontmost app.")) {
                if accessibilityTrusted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tokens.success).accessibilityHidden(true)
                } else {
                    HStack {
                        Button("Grant Access") {
                            CaretLocator.requestPermission()
                            accessibilityTrusted = CaretLocator.isTrusted
                        }
                        Button("Open System Settings") { Self.openAccessibilitySettings() }
                    }
                }
            }
        }
    }

    private var modelSection: some View {
        PaneSection("On-device model", footer: modelStatus.reason) {
            SettingsRow(title: "Refine with Apple Intelligence",
                        detail: Text("Re-ranks the top matches and phrases the reason using Foundation Models. Nothing leaves this Mac."),
                        enabled: modelStatus.isAvailable) {
                Toggle("Refine with Apple Intelligence", isOn: $useFoundationModels).labelsHidden()
                    .onChange(of: useFoundationModels) { _, value in SuggestionTuning.useFoundationModels = value }
            }
        }
    }

    private var cacheSection: some View {
        PaneSection("Embedding cache", footer: "Vectors are computed on this Mac and cached to speed up ranking.") {
            SettingsRow(title: "Cache size", detail: Text(PaneFormat.bytes(cacheBytes))) {
                Button("Clear Cache\u{2026}") { confirmClearCache = true }
            }
        }
    }

    private func refresh() {
        accessibilityTrusted = CaretLocator.isTrusted
        modelStatus = FoundationModelsAvailability.current()
        cacheBytes = Self.cacheFileBytes()
    }

    private static func cacheFileBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: EmbeddingCache.defaultFileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview("Intelligence settings") {
    IntelligenceSettingsPane().frame(width: 600, height: 760)
}
