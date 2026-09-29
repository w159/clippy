import Foundation

/// Every route that puts a clip into another app (FEAT-19). `PasteService`
/// resolves plain vs rich through `PasteProfileDecision` for each of them.
enum PasteRoute: CaseIterable {
    /// Panel Enter / click / hotkey paste of one clip.
    case paste
    /// The paste-plain hotkey (an explicit request: always plain, even for a "rich" profile).
    case pastePlainHotkey
    /// Next item from the paste stack (goes through `paste`).
    case pasteStack
    /// Several clips pasted one after another.
    case multiPasteSequence
    /// Several clips joined into one paste (text only, always plain).
    case multiPasteCombined
    /// A recent clip chosen from the status-item menu (goes through `paste`).
    case statusItem
    /// A file clip (files carry no rich/plain distinction).
    case file
}

/// Pure "paste plain?" decision across routes.
enum PasteProfileDecision {
    /// Whether the clip is written as plain text for `route` into `bundleID`.
    /// `callerAsksPlain` is the caller's own choice (global default or plain hotkey).
    static func shouldPastePlain(route: PasteRoute, bundleID: String?, callerAsksPlain: Bool) -> Bool {
        switch route {
        case .multiPasteCombined: return true
        case .file: return false
        case .pastePlainHotkey:
            // An explicit plain-text request is never downgraded by a "rich" profile.
            return true
        case .paste, .pasteStack, .multiPasteSequence, .statusItem:
            return PasteProfiles.shouldPastePlain(bundleID: bundleID, callerAsksPlain: callerAsksPlain)
        }
    }
}
