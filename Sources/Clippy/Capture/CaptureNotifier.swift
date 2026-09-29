import Foundation
@preconcurrency import UserNotifications

/// Posts the user-visible notification for events the user did not trigger
/// directly (a sensitive clip auto-cleared). Never includes clip content.
enum CaptureNotifier {
    /// Requests authorization on first use, then delivers. Silently does nothing
    /// outside an app bundle (unit tests, `swift run`), where UserNotifications
    /// has no identity to notify as.
    static func post(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
