import SwiftUI
import AppKit

// Status messaging for `ClipListView`: one entry point that feeds the
// design-system toast (transient) or banner (persistent), the OCR action and
// the paste/storage/category status hooks. Messages never carry clip content.

extension ClipListView {
    /// Severity callers pass to `showStatusBanner`; see `PanelStatusPolicy`.
    typealias StatusSeverity = PanelStatusSeverity

    /// Shows `message` with the given severity. Timing follows
    /// `PanelStatusPolicy`: failures and messages with a Retry stay until
    /// dismissed, others dismiss themselves. VoiceOver is notified by
    /// `PanelStatusOverlay`.
    func showStatusBanner(_ message: String, severity: StatusSeverity = .info, actionTitle: String = "Retry",
                          retry: (() -> Void)? = nil) {
        let hasAction = retry != nil
        let item = PanelStatusItem(
            message: message,
            severity: severity.banner,
            actionTitle: hasAction ? actionTitle : nil,
            isPersistent: PanelStatusPolicy.isPersistent(for: severity, hasAction: hasAction)
        )
        statusItem = item
        statusRetry = retry
        if let seconds = PanelStatusPolicy.autoDismissSeconds(for: severity, hasAction: hasAction) {
            dismissStatus(ifStill: item, after: seconds)
        }
    }

    /// Clears the current status message immediately.
    func dismissStatus() {
        statusItem = nil
        statusRetry = nil
    }

    /// Clears the message after `seconds` unless it was replaced meanwhile.
    func dismissStatus(ifStill item: PanelStatusItem, after seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if statusItem == item { dismissStatus() }
        }
    }

    /// Reports a finished paste when it needs attention (clean pastes are silent).
    func handlePasteResult(_ object: Any?) {
        guard let result = object as? PasteResult,
              let status = PanelStatusMessages.status(for: result) else { return }
        showStatusBanner(status.message, severity: status.severity == .danger ? .failure : .warning)
    }

    /// Reports the storage-ceiling warning once per change.
    func handleStorageWarning(_ usage: StorageUsage?) {
        guard let usage else { return }
        showStatusBanner(PanelStatusMessages.storageMessage(usage), severity: .warning)
    }

    /// Reports a category failure and clears the store flag so it can recur.
    func handleCategoryError(_ message: String?) {
        guard let message else { return }
        showStatusBanner(message, severity: .failure)
        store.categoryError = nil
    }

    /// Runs OCR on `clip`. Recognised text opens the OCR result sheet; nothing
    /// touches the clipboard implicitly (OCR-01). Other outcomes use the
    /// status message; failures carry a Retry that re-runs this on the same clip.
    func runOCR(on clip: Clip) {
        ClippyLog.info(
            "Extract Text requested for clip \(clip.id.map(String.init) ?? "nil")",
            category: ClippyLog.storage)
        OCRWarmupPolicy.shared.requestWarmup()
        let clipID = clip.id
        let presenter = OCRPresenter.shared
        presenter.begin(clipID: clipID)
        store.extractText(from: clip) { outcome in
            guard let banner = presenter.finish(clipID: clipID, outcome: outcome) else { return }
            var isFailure = false
            if case .failure = banner { isFailure = true }
            showStatusBanner(
                banner.message,
                severity: isFailure ? .failure : .info,
                retry: isFailure ? { runOCR(on: clip) } : nil
            )
        }
    }
}
