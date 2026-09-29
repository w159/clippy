import Combine
import Foundation
import UserNotifications

/// Live system state behind the walkthrough. Every value comes from the real API
/// (CaretLocator, AppSettings, OCRIndexPreferences, LaunchAtLogin, UNUserNotificationCenter).
@MainActor
final class OnboardingViewModel: ObservableObject {
    /// Step machine.
    @Published var model = OnboardingModel()
    /// Accessibility trust, polled while the window is open.
    @Published private(set) var accessibilityTrusted = CaretLocator.isTrusted
    /// Notification authorization.
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var requestingNotifications = false
    /// Login item state.
    @Published private(set) var launchStatus = LaunchAtLogin.status
    /// Last error from toggling the login item.
    @Published var launchError: String?
    /// Smart Suggestions opt-in mirror.
    @Published var suggestionsOn = AppSettings.shared.suggestionsEnabled
    /// OCR indexing opt-in mirror.
    @Published var ocrOn = OCRIndexPreferences.isEnabled

    private var timer: Timer?
    private var notificationRefreshTask: Task<Void, Never>?
    private var notificationRequestTask: Task<Void, Never>?
    private var didClose = false
    private let defaults: UserDefaults
    /// Called after the walkthrough finishes or is dismissed.
    var onClose: (() -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Starts 1s polling of permission state (it changes in System Settings).
    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Stops polling.
    func stopPolling() {
        timer?.invalidate()
        timer = nil
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
    }

    /// Re-reads all live state.
    func refresh() {
        // Assign only on change: the 1s poll must not re-render the walkthrough when nothing moved.
        let trusted = CaretLocator.isTrusted
        if accessibilityTrusted != trusted { accessibilityTrusted = trusted }
        let login = LaunchAtLogin.status
        if launchStatus != login { launchStatus = login }
        notificationRefreshTask?.cancel()
        notificationRefreshTask = Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard let self, !Task.isCancelled else { return }
            if self.notificationStatus != settings.authorizationStatus {
                self.notificationStatus = settings.authorizationStatus
            }
        }
    }

    /// Shows the system Accessibility prompt.
    func grantAccessibility() { CaretLocator.requestPermission() }

    /// Asks for notification permission (auto-clear alerts).
    func requestNotifications() {
        guard !requestingNotifications else { return }
        requestingNotifications = true
        notificationRequestTask = Task { [weak self] in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard let self, !Task.isCancelled else { return }
            self.requestingNotifications = false
            self.notificationRequestTask = nil
            self.refresh()
        }
    }

    /// Applies the suggestions opt-in.
    func setSuggestions(_ enabled: Bool) {
        AppSettings.shared.suggestionsEnabled = enabled
        suggestionsOn = AppSettings.shared.suggestionsEnabled
    }

    /// Applies the OCR opt-in through the single supported entry point.
    func setOCR(_ enabled: Bool) {
        OCRIndexer.setIndexingEnabled(enabled)
        ocrOn = OCRIndexPreferences.isEnabled
    }

    /// Toggles the login item, surfacing failures.
    func setLaunchAtLogin(_ enabled: Bool) {
        do { try LaunchAtLogin.set(enabled); launchError = nil } catch { launchError = error.localizedDescription }
        launchStatus = LaunchAtLogin.status
    }

    /// Continue / Get Started.
    func advance() {
        model.next()
        finishIfNeeded()
    }

    /// Skips the current step.
    func skipStep() {
        model.skip()
        finishIfNeeded()
    }

    /// "Skip for now": leave, remembering completion.
    func skipAll() {
        model.skipAll()
        finishIfNeeded()
    }

    /// Goes back.
    func back() { model.back() }

    private func finishIfNeeded() {
        guard model.isFinished, !didClose else { return }
        didClose = true
        model.persistIfFinished(defaults: defaults)
        stopPolling()
        onClose?()
    }
}
