import Foundation

/// FEAT-13 / FEAT-06 preferences, UserDefaults-backed through
/// `CapturePreferences.defaults` (so tests can swap a scratch suite). Keys:
/// `paste.append.enabled` (Bool, default false), `paste.append.window`
/// (Double seconds, default 1.5, clamped 0.3...10), `paste.append.separator`
/// (`MergeSeparator` raw value, default newline), `paste.stack.order`
/// (`PasteStackOrder` raw value, default fifo), `paste.merge.separator`
/// (`MergeSeparator` raw value used by "Merge selected clips", default newline).
enum AppendPreferences {
    enum Key {
        static let enabled = "paste.append.enabled"
        static let window = "paste.append.window"
        static let separator = "paste.append.separator"
        static let stackOrder = "paste.stack.order"
        static let mergeSeparator = "paste.merge.separator"
    }

    static let defaultWindow: TimeInterval = 1.5
    static let windowRange: ClosedRange<TimeInterval> = 0.3...10

    private static var defaults: UserDefaults { CapturePreferences.defaults }

    /// "Copy twice to append" mode. Off by default (it changes what a copy does).
    static var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Seconds within which a second copy from the same app is appended.
    static var window: TimeInterval {
        get {
            guard let stored = defaults.object(forKey: Key.window) as? Double else { return defaultWindow }
            return min(windowRange.upperBound, max(windowRange.lowerBound, stored))
        }
        set { defaults.set(min(windowRange.upperBound, max(windowRange.lowerBound, newValue)), forKey: Key.window) }
    }

    /// Separator used between an appended copy and the clip it joins.
    static var separator: MergeSeparator {
        get { defaults.string(forKey: Key.separator).flatMap(MergeSeparator.init(rawValue:)) ?? .newline }
        set { defaults.set(newValue.rawValue, forKey: Key.separator) }
    }

    /// Separator used by "Merge selected clips".
    static var mergeSeparator: MergeSeparator {
        get { defaults.string(forKey: Key.mergeSeparator).flatMap(MergeSeparator.init(rawValue:)) ?? .newline }
        set { defaults.set(newValue.rawValue, forKey: Key.mergeSeparator) }
    }

    /// Paste-stack pop order.
    static var stackOrder: PasteStackOrder {
        get { defaults.string(forKey: Key.stackOrder).flatMap(PasteStackOrder.init(rawValue:)) ?? .fifo }
        set { defaults.set(newValue.rawValue, forKey: Key.stackOrder) }
    }
}
