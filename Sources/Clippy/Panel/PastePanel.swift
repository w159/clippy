import AppKit

/// Borderless, nonactivating floating panel. It can take keyboard focus for
/// the search field without activating Clippy, so the frontmost app keeps
/// its active state and receives the simulated Cmd-V after selection.
final class PastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
