import Foundation

extension Notification.Name {
    /// Posted (main thread) with a `PasteResult` as `object` when a paste finishes.
    /// AppDelegate forwards `PasteService.onResult` through `PanelStatusMessages.post(_:)`.
    static let clippyPasteResult = Notification.Name("ClippyPasteResult")
}

/// Pure mapping from operation outcomes to banner text; messages carry
/// metadata only, never clip content.
enum PanelStatusMessages {
    /// Text and severity for a paste outcome, nil for a clean paste.
    static func status(for result: PasteResult) -> (message: String, severity: BannerSeverity)? {
        switch result {
        case .pasted:
            return nil
        case .copiedOnly(.accessibilityNotGranted):
            return ("Copied. Grant Accessibility access so Clippy can paste for you.", .warning)
        case .copiedOnly(.targetNotActivated):
            return ("Copied, but the target app did not come forward. Press \u{2318}V to paste.", .warning)
        case .failed(let error):
            return (error.message, .danger)
        }
    }

    /// Text for the storage-ceiling warning.
    static func storageMessage(_ usage: StorageUsage) -> String {
        let percent = usage.ceiling > 0 ? min(100, usage.count * 100 / usage.ceiling) : 100
        return "History is \(percent)% full (\(usage.count) of \(usage.ceiling) clips). Oldest clips will be removed at the limit."
    }

    /// Forwards a paste result to any open panel.
    static func post(_ result: PasteResult, center: NotificationCenter = .default) {
        center.post(name: .clippyPasteResult, object: result)
    }
}
