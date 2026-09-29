import AppKit
import SwiftUI

/// A database-isolated preview harness for the expanded and rail sidebars.
private struct SidebarPreviewHarness: View {
    @State private var selection: PanelSelection = .history
    private let store: ClipStore?

    init() {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-sidebar-preview-\(identifier)", isDirectory: true)
        let database = try? ClipDatabase(
            databaseURL: root.appendingPathComponent("preview.sqlite"),
            mediaDirectory: root.appendingPathComponent("media", isDirectory: true))
        store = database.map {
            ClipStore(database: $0, pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippySidebarPreview-\(identifier)")))
        }
    }

    var body: some View {
        Group {
            if let store {
                HStack(spacing: 0) {
                    CategorySidePane(store: store, selection: $selection)
                        .frame(width: 190)
                    Divider()
                    CategorySidePane(store: store, selection: $selection, isRail: true)
                        .frame(width: SidebarMetrics.railWidth)
                }
            } else {
                Text("Sidebar preview database unavailable")
            }
        }
        .frame(height: 440)
        .clippyDesignSystem()
    }
}

#Preview("Category sidebar") {
    SidebarPreviewHarness()
}
