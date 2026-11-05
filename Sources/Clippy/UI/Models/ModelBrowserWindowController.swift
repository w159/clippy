import AppKit
import SwiftUI

@MainActor
final class ModelBrowserWindowController: NSObject, NSWindowDelegate {
    static let shared = ModelBrowserWindowController()

    private var window: NSWindow?
    private var model: ModelBrowserViewModel?

    func present(providerID: UUID, currentModel: String, onSelect: @escaping @MainActor (String) -> Void) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Choose a Model"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let model = ModelBrowserViewModel(providerID: providerID, currentModel: currentModel, onSelect: onSelect)
        model.onClose = { [weak self] in self?.window?.close() }
        window.contentView = NSHostingView(rootView: ModelBrowserView(model: model).clippyDesignSystem())
        window.minSize = NSSize(width: 620, height: 400)
        window.center()
        window.setFrameAutosaveName("AIModelBrowser")
        self.model = model
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}
