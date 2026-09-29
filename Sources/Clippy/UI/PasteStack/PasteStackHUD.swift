import AppKit
import SwiftUI

/// Small non-activating toast window ("Stack: 3") shown while the panel is
/// hidden. Messages carry counts only, never clip content.
@MainActor
final class PasteStackHUD {
    private var window: NSPanel?
    private var hideTask: DispatchWorkItem?

    /// Shows `message` near the top of the main screen for `duration` seconds.
    func show(_ message: String, severity: BannerSeverity = .neutral, duration: TimeInterval = 1.4) {
        let host = NSHostingView(rootView: ClippyToast(message, severity: severity))
        host.frame.size = host.fittingSize
        let panel = window ?? NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 24))
        }
        panel.orderFrontRegardless()
        window = panel
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.window?.orderOut(nil) }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}
