import Foundation

/// Capture, paste, and OCR preferences owned by the capture area. Kept out of
/// `AppSettings` so the Settings redesign can wire UI to them without touching
/// this area; every accessor is UserDefaults-backed under a `capture.`/`ocr.`
/// prefix and safe to read from any thread.
enum CapturePreferences {

    /// Backing store; tests swap in a scratch suite.
    private static let seam = DefaultsSeam()
    static var defaults: UserDefaults {
        get { seam.value }
        set { seam.value = newValue }
    }

    enum Key {
        static let captureOnLaunch = "capture.onLaunch"
        static let typeBlocklist = "capture.typeBlocklist"
        static let sensitiveAutoClearSeconds = "capture.sensitiveAutoClearSeconds"
        static let autoClearDeletesHistory = "capture.autoClearDeletesHistory"
        static let flavorBudgetMB = "capture.flavorBudgetMB"
        static let preserveFlavors = "capture.preserveFlavors"
        static let pasteProfiles = "paste.profiles"
        static let ocrLanguages = "ocr.languages"
    }

    /// Capture whatever is already on the clipboard when the monitor starts.
    /// Off by default: a launch-time capture records something the user copied
    /// before Clippy was running.
    static var captureOnLaunch: Bool {
        get { defaults.bool(forKey: Key.captureOnLaunch) }
        set { defaults.set(newValue, forKey: Key.captureOnLaunch) }
    }

    /// Pasteboard type identifiers (UTIs) that make a copy invisible to Clippy.
    /// A copy is skipped when any of its types equals, or conforms to, an entry.
    static var typeBlocklist: [String] {
        get { defaults.stringArray(forKey: Key.typeBlocklist) ?? [] }
        set { defaults.set(newValue, forKey: Key.typeBlocklist) }
    }

    /// Seconds after which a sensitive clip is removed from the clipboard (and,
    /// with `autoClearDeletesHistory`, from history). 0 disables auto-clear.
    static var sensitiveAutoClearSeconds: Int {
        get { max(0, defaults.integer(forKey: Key.sensitiveAutoClearSeconds)) }
        set { defaults.set(max(0, newValue), forKey: Key.sensitiveAutoClearSeconds) }
    }

    /// Whether auto-clear also deletes the history row. Default true: leaving the
    /// secret in history would defeat clearing it from the clipboard.
    static var autoClearDeletesHistory: Bool {
        get { defaults.object(forKey: Key.autoClearDeletesHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoClearDeletesHistory) }
    }

    /// Whether extra pasteboard flavors (JPEG, PDF, vCard, RTFD, URL...) are kept
    /// and restored on paste.
    static var preserveFlavors: Bool {
        get { defaults.object(forKey: Key.preserveFlavors) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.preserveFlavors) }
    }

    /// Per-clip byte budget for preserved flavors (default 8 MB, 1...256).
    static var flavorBudgetMB: Int {
        get {
            let stored = defaults.integer(forKey: Key.flavorBudgetMB)
            return stored == 0 ? 8 : min(256, max(1, stored))
        }
        set { defaults.set(min(256, max(1, newValue)), forKey: Key.flavorBudgetMB) }
    }

    static var flavorBudgetBytes: Int { flavorBudgetMB * 1_048_576 }

    /// BCP-47 languages Vision should recognize; empty means automatic detection.
    static var ocrLanguages: [String] {
        get { defaults.stringArray(forKey: Key.ocrLanguages) ?? [] }
        set { defaults.set(newValue, forKey: Key.ocrLanguages) }
    }
}
