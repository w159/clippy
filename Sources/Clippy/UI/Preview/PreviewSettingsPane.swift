import SwiftUI

/// Settings for previews (FEAT-09/14): preview column, link previews (opt-in) and the link cache.
struct PreviewSettingsPane: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var columnOn = PreviewColumnPreferences.isEnabled()
    @State private var linksOn = LinkPreviewPreferences.isEnabled
    @State private var allowText = LinkPreviewPreferences.allowHosts.joined(separator: ", ")
    @State private var denyText = LinkPreviewPreferences.denyHosts.joined(separator: ", ")
    @State private var cacheBytes = LinkPreviewService.shared.cacheBytes

    /// Creates the pane.
    init() {}

    var body: some View {
        Form {
            Section("Preview column") {
                Toggle("Show preview column when the panel is wide", isOn: $columnOn)
                    .onChange(of: columnOn) { _, value in PreviewColumnPreferences.setEnabled(value) }
                Text("Appears on the right when the panel is at least \(Int(PreviewColumnPreferences.minPanelWidth)) pt wide.")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
            }
            Section("Link previews") {
                Toggle("Fetch link previews", isOn: $linksOn)
                    .onChange(of: linksOn) { _, value in LinkPreviewPreferences.isEnabled = value }
                Text(LinkPreviewPreferences.disclosure).font(.caption).foregroundStyle(tokens.textSecondary)
                Text("Never used for sensitive clips or addresses that contain credentials or token parameters.")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
                // Short labels: a long placeholder-as-label wrapped to two lines and squeezed the field.
                LabeledContent("Only these sites") {
                    TextField("Only these sites", text: $allowText, prompt: Text("example.com, docs.dev"))
                        .labelsHidden().multilineTextAlignment(.trailing)
                        .onSubmit { LinkPreviewPreferences.allowHosts = Self.hosts(allowText) }
                }
                LabeledContent("Never these sites") {
                    TextField("Never these sites", text: $denyText, prompt: Text("example.com, ads.net"))
                        .labelsHidden().multilineTextAlignment(.trailing)
                        .onSubmit { LinkPreviewPreferences.denyHosts = Self.hosts(denyText) }
                }
                Text("Comma separated. Leave the first empty to allow every site not in the second list.")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
                HStack {
                    Text("Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))")
                    Spacer()
                    Button("Clear cache") {
                        LinkPreviewService.shared.clearCache()
                        cacheBytes = LinkPreviewService.shared.cacheBytes
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            LinkPreviewPreferences.allowHosts = Self.hosts(allowText)
            LinkPreviewPreferences.denyHosts = Self.hosts(denyText)
        }
    }

    private static func hosts(_ text: String) -> [String] { text.split(separator: ",").map(String.init) }
}
