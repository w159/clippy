import Foundation
import os

/// The most recent `ContextReader.capture`, kept so the Suggestions pane can show
/// a Diagnostics popover (ROADMAP INT-01). Holds the app name, bundle id, a
/// character COUNT and elapsed time only: never any screen text.
final class ContextCaptureLog: Sendable {
    static let shared = ContextCaptureLog()

    /// One capture attempt.
    struct Entry: Equatable {
        var appName: String?
        var bundleID: String?
        /// Characters of text read from the focused element; nil when no context was returned.
        var textCharacters: Int?
        var elapsedMillis: Int
        var capturedAt: Date

        /// True when a non-empty text body was read.
        var didReadText: Bool { (textCharacters ?? 0) > 0 }
    }

    private let entry = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    /// Stores the latest capture, replacing the previous one.
    func record(
        appName: String?, bundleID: String?, textCharacters: Int?, elapsed: TimeInterval,
        now: Date = Date()
    ) {
        entry.withLock {
            $0 = Entry(
                appName: appName, bundleID: bundleID, textCharacters: textCharacters,
                elapsedMillis: Int(elapsed * 1000), capturedAt: now)
        }
    }

    /// The last capture, or nil before the first one.
    var last: Entry? {
        entry.withLock { $0 }
    }

    /// Forgets the last capture (privacy: called with the suggestions context).
    func reset() {
        entry.withLock { $0 = nil }
    }
}
