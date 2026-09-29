import Foundation

/// Pure decision for "copy twice to append" (FEAT-13). No clock, database or
/// pasteboard access: everything is injected so the rule is unit-testable.
enum ClipAppendPolicy {
    /// The previously captured (non-sensitive) text clip.
    struct Previous: Equatable {
        let clipID: Int64
        let date: Date
        let bundleID: String?
        let text: String
    }

    /// What to do with an incoming text copy.
    enum Decision: Equatable {
        /// Store it as its own clip.
        case insertNew
        /// Replace clip `clipID`'s text with `merged`.
        case append(clipID: Int64, merged: String)
    }

    /// Upper bound on a merged clip, so a long chain of copies cannot grow forever.
    static let maxMergedLength = 1_000_000

    /// Decides for one incoming copy. Appends only when the mode is on, the previous
    /// clip is within `window` seconds, both copies come from the same known app,
    /// neither the incoming text nor the merge is sensitive, the text is not blank
    /// and is not a re-copy of exactly the previous text.
    static func decide(
        previous: Previous?, incomingText: String, incomingBundleID: String?, incomingIsSensitive: Bool,
        now: Date, window: TimeInterval, separator: String, enabled: Bool,
        mergedIsSensitive: (String) -> Bool = { SensitiveContent.isSensitive(text: $0) }
    ) -> Decision {
        guard enabled, !incomingIsSensitive, let previous,
              let bundle = incomingBundleID, bundle == previous.bundleID,
              incomingText.contains(where: { !$0.isWhitespace }),
              incomingText != previous.text
        else { return .insertNew }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed >= 0, elapsed <= window else { return .insertNew }
        let merged = previous.text + separator + incomingText
        guard merged.count <= maxMergedLength, !mergedIsSensitive(merged) else { return .insertNew }
        return .append(clipID: previous.clipID, merged: merged)
    }
}

/// Remembers the last non-sensitive text capture so the monitor can apply
/// `ClipAppendPolicy`. Thread-safe; touched from the capture queue.
///
/// `@unchecked Sendable`: `previous` is only read or written under `lock`.
final class ClipAppendTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: ClipAppendPolicy.Previous?

    /// Evaluates an incoming copy against the remembered one. An append advances the
    /// remembered clip to the merged text and time, so a third copy chains on.
    func evaluate(text: String, bundleID: String?, sensitive: Bool, now: Date) -> ClipAppendPolicy.Decision {
        lock.lock()
        defer { lock.unlock() }
        let decision = ClipAppendPolicy.decide(
            previous: previous, incomingText: text, incomingBundleID: bundleID, incomingIsSensitive: sensitive,
            now: now, window: AppendPreferences.window, separator: AppendPreferences.separator.text,
            enabled: AppendPreferences.isEnabled)
        if case .append(let clipID, let merged) = decision {
            previous = ClipAppendPolicy.Previous(clipID: clipID, date: now, bundleID: bundleID, text: merged)
        }
        return decision
    }

    /// Remembers a freshly stored clip; a sensitive or id-less one clears the memory.
    func recordSaved(clipID: Int64?, text: String, bundleID: String?, date: Date, sensitive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let clipID, !sensitive else { previous = nil; return }
        previous = ClipAppendPolicy.Previous(clipID: clipID, date: date, bundleID: bundleID, text: text)
    }

    /// Forgets the remembered clip (image/file captures, pause, delete).
    func forget() {
        lock.lock()
        previous = nil
        lock.unlock()
    }
}
