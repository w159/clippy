import Foundation

/// Decides when the Vision OCR models are worth warming (OCR-02).
///
/// A cold first recognition can cost ~24s, but warming on every panel open or
/// at launch burns CPU/memory for users who never OCR. Warm-up is therefore
/// requested only when an image-like clip is visible, hovered or selected, or
/// OCR is asked for, and is rate-limited (default once per 10 minutes). Never
/// at launch.
final class OCRWarmupPolicy: @unchecked Sendable {
    /// Process-wide policy used by the panel and card views.
    static let shared = OCRWarmupPolicy()

    /// Minimum seconds between two warm-ups.
    let minimumInterval: TimeInterval

    /// Returns true when at least one image-like clip exists. Set by the
    /// panel/store owner; defaults to "no image clips" so `panelDidShow()` is
    /// a no-op until wired.
    var hasImageClips: () -> Bool {
        get { lock.withLock { probe } }
        set { lock.withLock { probe = newValue } }
    }

    private let now: () -> Date
    private let warm: () -> Void
    private let lock = NSLock()
    private var lastWarmUp: Date?
    private var probe: () -> Bool = { false }

    /// - Parameters:
    ///   - minimumInterval: rate limit between warm-ups (default 600s).
    ///   - now: injectable clock.
    ///   - warm: the warm-up action (default `OCRService.warmUp`).
    init(
        minimumInterval: TimeInterval = 600,
        now: @escaping () -> Date = Date.init,
        warm: @escaping () -> Void = { OCRService.warmUp() }
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.warm = warm
    }

    /// Warms unless one already ran within `minimumInterval`.
    /// - Returns: true when a warm-up was started.
    @discardableResult
    func requestWarmup() -> Bool {
        let current = now()
        let shouldWarm = lock.withLock { () -> Bool in
            if let last = lastWarmUp, current.timeIntervalSince(last) < minimumInterval { return false }
            lastWarmUp = current
            return true
        }
        if shouldWarm { warm() }
        return shouldWarm
    }

    /// An image-like clip became visible, hovered or selected.
    func noteImageVisible() { requestWarmup() }

    /// The panel was shown: warm only when image clips exist.
    func panelDidShow() {
        guard hasImageClips() else { return }
        requestWarmup()
    }

    /// Forgets the last warm-up time (used when settings/OCR state is reset).
    func reset() { lock.withLock { lastWarmUp = nil } }
}
