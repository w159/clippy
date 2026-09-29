import SwiftUI

/// Settings for semantic search and auto-filing. Everything here runs on this
/// Mac; no clip content is sent anywhere. Assets are downloaded only when the
/// user presses the button.
struct SemanticSettingsPane: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var semanticOn = SemanticSearchPreferences.standard.isEnabled
    @State private var autoFileOn = SemanticSearchPreferences.standard.isAutoFileEnabled
    @State private var refineOn = SemanticSearchPreferences.standard.isFoundationRefinementEnabled
    @State private var assetsReady = NLContextualTextEmbedder().hasAvailableAssets
    @State private var downloading = false

    /// Creates the pane; state is read from `SemanticSearchPreferences.standard`.
    init() {}

    var body: some View {
        Form {
            Section("Semantic search") {
                Toggle("Search by meaning", isOn: $semanticOn)
                    .onChange(of: semanticOn) { _, value in SemanticSearchPreferences.standard.isEnabled = value }
                Text("Ranks clips by meaning as well as keywords. Embeddings are computed on this Mac and stored in a local cache; sensitive clips are never embedded.")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
                LabeledContent("Language model assets", value: assetsReady ? "Installed" : "Not installed")
                if !assetsReady {
                    Button(downloading ? "Downloading\u{2026}" : "Download assets (Apple)") { download() }
                        .disabled(downloading)
                }
            }
            Section("Category suggestions") {
                Toggle("Suggest categories for uncategorized clips", isOn: $autoFileOn)
                    .onChange(of: autoFileOn) { _, value in SemanticSearchPreferences.standard.isAutoFileEnabled = value }
                Toggle("Refine with the on-device system language model", isOn: $refineOn)
                    .disabled(!autoFileOn)
                    .onChange(of: refineOn) { _, value in SemanticSearchPreferences.standard.isFoundationRefinementEnabled = value }
                Text("Suggestions are never applied until you accept them. Only a short preview and category names reach the on-device model.")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    private func download() {
        downloading = true
        Task {
            let ok = await NLContextualTextEmbedder().requestAssets()
            assetsReady = ok
            downloading = false
        }
    }
}
