import Combine
import Foundation

/// Presentation state for Extract Text (OCR-01, OCR-11). Pure logic, no views:
/// which clips are being recognised (drives the scrim) and which result sheet
/// is showing. Shared so `ClipListView+StatusBanner.runOCR` can drive it
/// without stored state on `ClipListView`.
@MainActor
final class OCRPresenter: ObservableObject {
    static let shared = OCRPresenter()

    /// One recognised text awaiting the user's decision.
    struct Result: Identifiable, Equatable {
        let id = UUID()
        /// Source clip, when it has an identity.
        let clipID: Int64?
        let text: String

        /// Whitespace-separated word count.
        var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
        /// Character count (grapheme clusters).
        var characterCount: Int { text.count }
    }

    /// Clips with an extraction in flight; the scrim/spinner shows while non-empty.
    @Published private(set) var runningClipIDs: Set<Int64> = []
    /// Non-nil while the result sheet is showing.
    @Published private(set) var result: Result?
    /// Runs in flight for clips without an id (never persisted).
    @Published private(set) var anonymousRuns = 0

    /// True while any extraction runs.
    var isRunning: Bool { !runningClipIDs.isEmpty || anonymousRuns > 0 }

    /// Whether the scrim covers the card of `clipID`.
    func isScrimVisible(for clipID: Int64?) -> Bool {
        guard let clipID else { return anonymousRuns > 0 }
        return runningClipIDs.contains(clipID)
    }

    /// An extraction started.
    func begin(clipID: Int64?) {
        if let clipID { runningClipIDs.insert(clipID) } else { anonymousRuns += 1 }
    }

    /// An extraction ended. Text outcomes open the sheet; others are returned
    /// unchanged for the caller to show as a banner.
    /// - Returns: the outcome when it still needs a banner, nil when the sheet took it.
    @discardableResult
    func finish(clipID: Int64?, outcome: OCRExtractOutcome) -> OCRExtractOutcome? {
        // "Already running" answers must not clear the run that IS running.
        let isDuplicateNotice: Bool = {
            if case .notice(let notice) = outcome { return notice.contains("already running") }
            return false
        }()
        if !isDuplicateNotice {
            if let clipID { runningClipIDs.remove(clipID) } else { anonymousRuns = max(0, anonymousRuns - 1) }
        }
        if case .text(let text) = outcome {
            result = Result(clipID: clipID, text: text)
            return nil
        }
        return outcome
    }

    /// Close the result sheet.
    func dismiss() { result = nil }
}
