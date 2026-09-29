import AppKit

/// Remembers which app was active when, so a copy can be attributed to the app
/// that made it rather than the app that happens to be frontmost when the poll
/// timer fires (CAP-04). Fed by `NSWorkspace.didActivateApplicationNotification`.
///
/// `@unchecked Sendable`: `history` is only touched under `lock`; `observer` is set once in `init`.
final class SourceAppTracker: @unchecked Sendable {
    struct App: Equatable {
        let bundleID: String
        let name: String?
    }

    private struct Activation {
        let app: App
        let at: Date
    }

    /// Pasteboard type carrying the copying app's bundle id, set by
    /// well-behaved apps (nspasteboard.org convention).
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    private let lock = NSLock()
    private var history: [Activation] = []
    private let maxEntries = 16
    private var observer: NSObjectProtocol?
    private let ownBundleID: String?

    /// `ownBundleID` activations (Clippy's own panel) are not recorded: they are
    /// never the app a copy should be attributed to.
    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         ownBundleID: String? = Bundle.main.bundleIdentifier,
         seedFromFrontmost: Bool = true) {
        self.ownBundleID = ownBundleID
        if seedFromFrontmost, let current = NSWorkspace.shared.frontmostApplication,
           let id = current.bundleIdentifier, id != ownBundleID {
            history.append(Activation(app: App(bundleID: id, name: current.localizedName), at: Date()))
        }
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self?.record(bundleID: id, name: app.localizedName, at: Date())
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Appends an activation. Internal so tests can drive it deterministically.
    func record(bundleID: String, name: String?, at date: Date) {
        guard bundleID != ownBundleID else { return }
        lock.withLock {
            if history.last?.app.bundleID == bundleID { return }
            history.append(Activation(app: App(bundleID: bundleID, name: name), at: date))
            if history.count > maxEntries { history.removeFirst(history.count - maxEntries) }
        }
    }

    /// The most recent non-Clippy app, i.e. the paste target while the panel is up.
    var lastExternalApp: App? { lock.withLock { history.last?.app } }

    /// The app that was active at `date` (the last activation at or before it).
    func app(at date: Date) -> App? {
        lock.withLock { history.last(where: { $0.at <= date })?.app }
    }

    /// Apps that could have made a copy first observed at `now`, given the
    /// previous poll at `since`: the app active at `since`, plus every app
    /// activated since. When an activation fell inside the window the true
    /// source is ambiguous, so callers apply ignore lists to all candidates.
    func candidates(since: Date, now: Date = Date()) -> [App] {
        lock.withLock {
            var result: [App] = []
            if let before = history.last(where: { $0.at <= since }) { result.append(before.app) }
            result += history.filter { $0.at > since && $0.at <= now }.map(\.app)
            if result.isEmpty, let last = history.last { result.append(last.app) }
            return result
        }
    }

    /// Bundle id from the pasteboard's `org.nspasteboard.source` hint, if any.
    static func hint(from pasteboard: NSPasteboard) -> String? {
        guard let value = pasteboard.string(forType: sourceType)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 256 else { return nil }
        return value
    }

    /// Display name for a bundle id via the app's bundle, or nil.
    static func displayName(forBundleID bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The attribution for a copy: the pasteboard hint first, then the app that
    /// was active for the copy. `all` lists every plausible source (the hint
    /// plus the activation-history candidates) so the ignore list is applied to
    /// all of them.
    func attribution(pasteboard: NSPasteboard, lastPoll: Date, now: Date = Date()) -> (primary: App?, all: [App]) {
        if let hinted = Self.hint(from: pasteboard) {
            let app = App(bundleID: hinted, name: Self.displayName(forBundleID: hinted))
            return (app, [app] + candidates(since: lastPoll, now: now))
        }
        let all = candidates(since: lastPoll, now: now)
        // The latest candidate is the best single answer; the rest only widen
        // the set the ignore list is applied to.
        return (all.last, all)
    }
}
