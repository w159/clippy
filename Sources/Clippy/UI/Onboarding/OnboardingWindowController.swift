import AppKit
import SwiftUI

/// Owns the onboarding window. Shown once (`onboarding.completedVersion`) and
/// on demand from Help > Show Welcome.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?

    /// Shows the walkthrough, or fronts it if already open.
    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = OnboardingViewModel()
        model.onClose = { [weak self] in self?.close() }
        // The design system resolves the user's theme; without it the view fell back to the default seed palette.
        let window = Self.makeWindow(rootView: OnboardingView(viewModel: model).clippyDesignSystem())
        window.delegate = self
        window.center()
        self.window = window
        viewModel = model
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The walkthrough window: the glass card is the whole window, like the panel.
    /// The hosting view drops the titlebar safe area so the card fills the window
    /// instead of sitting below an empty transparent strip, and the traffic lights
    /// are hidden because they would float over the card's header. Skip for now is
    /// the cancel action, so Escape closes the window as the close button did.
    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Clippy"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let hosting = NSHostingView(rootView: rootView)
        hosting.safeAreaRegions = []
        window.contentView = hosting
        return window
    }

    /// Shows only when the user has not completed the current version.
    func showIfNeeded() {
        if OnboardingModel.needsOnboarding() { show() }
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing with the red button counts as dismissing: do not nag again.
        OnboardingModel.markCompleted()
        viewModel?.stopPolling()
        window = nil
        viewModel = nil
    }
}
