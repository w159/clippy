import Foundation

/// Per-app paste behavior (CAP-08): which target apps always get plain text.
/// Terminals and code editors mangle or mis-render rich text, so they default
/// to plain; the user can override any app (or add others) and the override wins.
enum PasteProfiles {
    enum Mode: String {
        /// Follow the caller's / global setting.
        case automatic
        /// Always paste plain text into this app.
        case plainText
        /// Always paste rich text into this app, even where the built-in profile says plain.
        case rich
    }

    /// Built-in plain-text targets: terminals and IDEs / code editors.
    static let builtInPlainTextBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3",
        "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.rubymine", "com.jetbrains.AppCode",
        "com.google.android.studio", "com.panic.Nova", "com.barebones.bbedit", "com.macromates.TextMate",
        "org.vim.MacVim", "com.qvacua.VimR",
    ]

    /// The user's explicit per-app choices, by bundle id.
    static var overrides: [String: Mode] {
        get {
            let raw = CapturePreferences.defaults.dictionary(forKey: CapturePreferences.Key.pasteProfiles) as? [String: String] ?? [:]
            return raw.compactMapValues(Mode.init(rawValue:))
        }
        set {
            CapturePreferences.defaults.set(newValue.mapValues(\.rawValue), forKey: CapturePreferences.Key.pasteProfiles)
        }
    }

    /// Sets (or with `.automatic` clears) the user's choice for `bundleID`.
    static func setMode(_ mode: Mode, forBundleID bundleID: String) {
        var current = overrides
        current[bundleID] = mode == .automatic ? nil : mode
        overrides = current
    }

    /// The effective mode for `bundleID`: the user's override, else the built-in
    /// profile, else `.automatic`.
    static func mode(forBundleID bundleID: String?) -> Mode {
        guard let bundleID else { return .automatic }
        if let override = overrides[bundleID] { return override }
        return builtInPlainTextBundleIDs.contains(bundleID) ? .plainText : .automatic
    }

    /// Whether a paste into `bundleID` should be plain text, given the plain-text
    /// choice the caller already made.
    static func shouldPastePlain(bundleID: String?, callerAsksPlain: Bool) -> Bool {
        switch mode(forBundleID: bundleID) {
        case .plainText: return true
        case .rich: return false
        case .automatic: return callerAsksPlain
        }
    }
}
