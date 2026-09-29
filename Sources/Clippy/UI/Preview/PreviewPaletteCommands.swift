import Foundation

/// Palette commands for previews. Wire into the palette host alongside `BuiltInCommands`.
enum PreviewPaletteCommands {
    /// Quick Look (needs a selected clip), toggle preview column, toggle link previews.
    @MainActor
    static func commands(selectedClip: Clip?, onColumnChanged: @escaping () -> Void = {}) -> [PaletteCommand] {
        let columnOn = PreviewColumnPreferences.isEnabled()
        let linksOn = LinkPreviewPreferences.isEnabled
        return [
            ClosurePaletteCommand(id: "quick-look", title: "Quick Look", symbol: "eye", keywords: ["preview", "space", "view"],
                                  shortcut: "Space", isEnabled: selectedClip != nil) {
                if let selectedClip { QuickLookController.shared.toggle(for: selectedClip) }
            },
            ClosurePaletteCommand(id: "toggle-preview-column", title: columnOn ? "Hide preview column" : "Show preview column",
                                  symbol: "sidebar.right", keywords: ["preview", "pane", "column"], section: .navigate) {
                PreviewColumnPreferences.setEnabled(!columnOn)
                onColumnChanged()
            },
            ClosurePaletteCommand(id: "toggle-link-previews", title: linksOn ? "Turn off link previews" : "Turn on link previews",
                                  subtitle: "Fetching sends the address to the website", symbol: "link",
                                  keywords: ["url", "preview", "network"], section: .settings) {
                LinkPreviewPreferences.isEnabled = !linksOn
            }
        ]
    }
}
