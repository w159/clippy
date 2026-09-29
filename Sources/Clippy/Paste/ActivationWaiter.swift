import AppKit

/// Waits for a condition that becomes true when the target app is key again,
/// driven by `NSWorkspace.didActivateApplicationNotification` with a timeout,
/// instead of a fixed sleep (CAP-06). Main-thread only.
@MainActor
enum ActivationWaiter {
    /// Calls `completion(true)` once `isReady()` holds, or `completion(false)` if
    /// `timeout` elapses first. `completion` runs exactly once, always
    /// asynchronously on the main queue, including when already ready (that one
    /// run-loop hop lets a just-dismissed panel finish handing back focus).
    static func wait(
        until isReady: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 0.6,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        Waiter(isReady: isReady, center: center, completion: completion).start(timeout: timeout)
    }

    /// One pending wait. The notification, the timeout and the immediate path all
    /// arrive on the main queue, so they re-enter the main actor with `assumeIsolated`.
    @MainActor
    private final class Waiter {
        private let isReady: @MainActor () -> Bool
        private let center: NotificationCenter
        private let completion: @MainActor (Bool) -> Void
        private var finished = false
        private var observer: NSObjectProtocol?
        private var timeoutItem: DispatchWorkItem?

        init(isReady: @escaping @MainActor () -> Bool, center: NotificationCenter,
             completion: @escaping @MainActor (Bool) -> Void) {
            self.isReady = isReady
            self.center = center
            self.completion = completion
        }

        func start(timeout: TimeInterval) {
            if isReady() {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(true) } }
                return
            }
            observer = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { if self.isReady() { self.finish(true) } }
            }
            let item = DispatchWorkItem { MainActor.assumeIsolated { self.finish(self.isReady()) } }
            timeoutItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        private func finish(_ ready: Bool) {
            guard !finished else { return }
            finished = true
            if let observer { center.removeObserver(observer) }
            timeoutItem?.cancel()
            completion(ready)
        }
    }
}
