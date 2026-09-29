import AppKit

/// Borderless, nonactivating floating panel. It can take keyboard focus for
/// the search field without activating Clippy, so the frontmost app keeps
/// its active state and receives the simulated Cmd-V after selection.
final class PastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// `.titled` + `.fullSizeContentView` makes AppKit supply the resize edges and
    /// cursors (PNL-02); the titlebar is then hidden so the SwiftUI glass content
    /// fills the whole window. `.nonactivatingPanel` keeps the frontmost app active.
    static let chromeStyleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable]

    /// Hides the titlebar and traffic lights and makes the window movable by its
    /// header drag region only (PNL-01), with a clear, shadowed glass backdrop.
    func applyChrome() {
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    /// Bound by PanelController so Escape routes through hide() (which saves the
    /// panel origin and remembered size) instead of a bare orderOut(nil) that
    /// would discard them.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        let settings = AppSettings.shared
        // Pinned panel ignores all auto-hide triggers, including Escape.
        guard !settings.panelPinned, settings.hideOnEscape else { return }
        if let onCancel {
            onCancel()
        } else {
            orderOut(nil)
        }
    }
}
