import AppKit
import Combine
import SwiftUI

// MARK: - Content hosting

extension PanelController {
    /// Builds the panel content: the lock view when `locked`, else the clip list.
    func installContent(in panel: PastePanel, locked: Bool) {
        showsLockView = locked
        if locked {
            let view = LockView(lock: AppLock.shared, onClose: { [weak self] in self?.hide() })
            panel.contentView = clearHostingView(view.clippyDesignSystem())
            return
        }
        let root = ClipListView(
            store: store,
            onPaste: { [weak self] clip, asPlainText in self?.onPaste?(clip, asPlainText) },
            onPasteMany: { [weak self] clips, combined, asPlainText in
                self?.onPasteMany?(clips, combined, asPlainText)
            },
            onPasteFile: { [weak self] clip, move in self?.onPasteFile?(clip, move) },
            onPrimary: { [weak self] clip in self?.onPrimary?(clip) },
            onSendKeystrokes: { [weak self] clip in self?.onSendKeystrokes?(clip) },
            onEdit: { [weak self] clip in self?.onEdit?(clip) },
            onClose: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                // Settings opens alongside the panel; panel stays visible.
                self?.onOpenSettings?()
            }
        )
        panel.contentView = clearHostingView(root.clippyDesignSystem())
    }

    /// Swaps the lock view for the clip list when the lock opens, and back to the
    /// lock view if it re-engages while the panel is visible.
    func observeLockState() {
        lockCancellable = AppLock.shared.$isLocked
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                guard let self, let panel = self.panel, panel.isVisible,
                      locked != self.showsLockView else { return }
                self.installContent(in: panel, locked: locked)
            }
    }

    /// Hosts SwiftUI content with a clear layer and no titlebar safe area, so the
    /// content's own GlassSurface is the window backdrop under the hidden titlebar.
    func clearHostingView<Root: View>(_ root: Root) -> NSHostingView<Root> {
        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        return hosting
    }
}
