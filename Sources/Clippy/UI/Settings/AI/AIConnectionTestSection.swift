import SwiftUI

struct AIConnectionTestSection: View {
    @ObservedObject var model: AIProviderManagerModel
    let providerID: UUID
    @ObservedObject private var health = AIHealth.shared

    var body: some View {
        PaneSection("Test connection") {
            HStack {
                Button(model.testing.contains(providerID) ? "Testing…" : "Test connection") {
                    Task { await model.test(providerID) }
                }.disabled(model.testing.contains(providerID)).settingsRow("ai.test")
                if model.testing.contains(providerID) { ProgressView().controlSize(.small) }
            }
            SettingsNote("Sends a short sample request, even when AI features are disabled.")
            if let failure = health.lastFailure {
                SettingsStatusLine(kind: .warning, text: "Last AI failure: \(failure)")
            }
            if let result = model.results[providerID] {
                SettingsStatusLine(kind: result.ok ? .success : .failure, text: result.summary)
                if let detail = result.detail { SettingsNote(detail) }
                if let latency = result.latency { SettingsNote(String(format: "Latency: %.2f seconds", latency)) }
                SettingsNote("Request URL: \(result.requestURLDisplay)")
            }
        }
    }
}
