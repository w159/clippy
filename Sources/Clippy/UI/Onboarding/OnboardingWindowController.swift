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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Clippy"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(viewModel: model))
        window.center()
        self.window = window
        viewModel = model
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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
