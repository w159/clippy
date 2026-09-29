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
                TextField("Only these sites (comma separated, optional)", text: $allowText)
                    .onSubmit { LinkPreviewPreferences.allowHosts = Self.hosts(allowText) }
                TextField("Never these sites (comma separated)", text: $denyText)
                    .onSubmit { LinkPreviewPreferences.denyHosts = Self.hosts(denyText) }
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
