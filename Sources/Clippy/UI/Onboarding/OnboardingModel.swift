import Foundation

/// One screen of the first-run walkthrough.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, accessibility, suggestions, ocr, hotkey, launchAtLogin, notifications, privacy

    var id: Int { rawValue }

    /// Sidebar/header title.
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .accessibility: return "Accessibility"
        case .suggestions: return "Smart Suggestions"
        case .ocr: return "Image text search"
        case .hotkey: return "Shortcut"
        case .launchAtLogin: return "Launch at login"
        case .notifications: return "Notifications"
        case .privacy: return "Privacy"
        }
    }

    /// Every step can be skipped without changing its associated setting.
    var isSkippable: Bool { true }
}

/// Pure state machine for the walkthrough: order, skipping, completion and
/// persistence of `onboarding.completedVersion`.
struct OnboardingModel: Equatable {
    /// Bump to show onboarding again after a release that adds steps.
    static let currentVersion = 1
    /// UserDefaults key holding the version the user last completed.
    static let completedVersionKey = "onboarding.completedVersion"

    /// Step being shown.
    private(set) var current: OnboardingStep = .welcome
    /// Steps the user skipped rather than acted on.
    private(set) var skipped: Set<OnboardingStep> = []
    /// True once `finish()` ran.
    private(set) var isFinished = false

    init() {}

    /// Whether onboarding must appear at launch.
    static func needsOnboarding(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completedVersionKey) < currentVersion
    }

    /// Records completion so it does not reappear.
    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: completedVersionKey)
    }

    /// 1-based position for "n of total".
    var position: Int { current.rawValue + 1 }
    /// Total number of steps.
    var total: Int { OnboardingStep.allCases.count }
    var isFirst: Bool { current == OnboardingStep.allCases.first }
    var isLast: Bool { current == OnboardingStep.allCases.last }

    /// Advances one step; on the last step finishes instead.
    mutating func next() {
        if let following = OnboardingStep(rawValue: current.rawValue + 1) { current = following } else { isFinished = true }
    }

    /// Goes back one step (no-op on the first). Leaving a step by Back clears its skip mark.
    mutating func back() {
        guard let previous = OnboardingStep(rawValue: current.rawValue - 1) else { return }
        current = previous
        skipped.remove(previous)
    }

    /// Skips the current step when skippable, then advances.
    mutating func skip() {
        guard current.isSkippable else { return }
        skipped.insert(current)
        next()
    }

    /// Jumps straight to the end ("Skip for now"): every unvisited step counts as skipped.
    mutating func skipAll() {
        for step in OnboardingStep.allCases where step.rawValue >= current.rawValue { skipped.insert(step) }
        isFinished = true
    }

    /// Ends the walkthrough.
    mutating func finish() { isFinished = true }

    /// Persists completion when finished; returns whether it was written.
    @discardableResult
    func persistIfFinished(defaults: UserDefaults = .standard) -> Bool {
        guard isFinished else { return false }
        Self.markCompleted(defaults: defaults)
        return true
    }

    /// A fresh walkthrough for "Show Welcome" (persisted completion is left alone).
    static func reopened() -> OnboardingModel { OnboardingModel() }
}
