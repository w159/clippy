import AppKit
import Quartz
import SwiftUI

/// `QLPreviewItem` wrapper for one materialized temp file.
final class ClipQuickLookItem: NSObject, QLPreviewItem, Sendable {
    let url: URL
    let title: String

    /// Wraps a temp file URL.
    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    /// QLPreviewItem: file URL.
    var previewItemURL: URL? { url }
    /// QLPreviewItem: title.
    var previewItemTitle: String? { title }
}

/// Space-bar Quick Look (LAY-11). Image/file clips open `QLPreviewPanel` on a 0600 temp copy that is removed
/// when the panel closes; text clips open an in-app large preview window. Sensitive clips do nothing.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Shared instance.
    static let shared = QuickLookController()

    private let temp = QuickLookTempFiles()
    private var items: [ClipQuickLookItem] = []
    private var textWindow: NSWindow?

    /// Opens the preview for the clip, or closes it when already open.
    func toggle(for clip: Clip) {
        if isVisible { close(); return }
        guard !CardSensitivity.isSensitive(clip) else { return }
        switch clip.contentKind {
        case .image, .file: openPanel(for: clip)
        case .text: openTextSheet(for: clip)
        }
    }

    /// True while either surface is showing.
    var isVisible: Bool { (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) || textWindow?.isVisible == true }

    /// Closes any open preview and removes temp files.
    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().dataSource === self { QLPreviewPanel.shared().orderOut(nil) }
        textWindow?.close()
        textWindow = nil
        release()
    }

    private func openPanel(for clip: Clip) {
        guard let source = ClipCardView.previewURL(for: clip),
              let copy = try? temp.materialize(copyOf: source) else { return }
        items = [ClipQuickLookItem(url: copy, title: clip.displayTitle)]
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    private func openTextSheet(for clip: Clip) {
        let item = ClipPreviewProvider.item(for: clip, lineLimit: .max)
        let view = QuickLookTextSheet(item: item, title: clip.displayTitle) { [weak self] in self?.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = clip.displayTitle
        window.contentView = NSHostingView(rootView: view.clippyDesignSystem())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        textWindow = window
    }

    private func release() {
        items = []
        temp.cleanUp()
    }

    // MARK: QLPreviewPanelDataSource / Delegate

    /// Item count for the panel.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { items.count } }

    /// Item at index.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { items[index] }
    }

    /// Cleans temp files once the panel is dismissed.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 || event.keyCode == 49 {
            MainActor.assumeIsolated { close() }
            return true
        }
        return false
    }
}

/// Large in-app preview for text clips.
struct QuickLookTextSheet: View {
    @Environment(\.clippyTokens) private var tokens
    let item: ClipPreviewItem
    let title: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { ClipPreviewView(item: item, lineLimit: nil).padding(tokens.metrics.space.four) }
            Divider()
            HStack {
                Text(item.kindLabel).font(.caption).foregroundStyle(tokens.textSecondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(tokens.metrics.space.two)
        }
        .background(tokens.surface)
        .frame(minWidth: 480, minHeight: 320)
    }
}
