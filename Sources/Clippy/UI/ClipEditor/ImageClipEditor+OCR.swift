import AppKit
import SwiftUI

// Extract Text (OCR-01, OCR-04): explicit action; the result is shown, never written to the pasteboard implicitly.
extension ImageClipEditor {
    /// Runs recognition on the stored image and presents the result sheet. The
    /// editor uses local state instead of `OCRPresenter.shared.finish` so the
    /// panel's own result sheet does not also open.
    func extractText() {
        guard !ocrRunning else { return }
        ocrNotice = nil
        ocrRunning = true
        OCRWarmupPolicy.shared.requestWarmup()
        store.extractText(from: clip) { outcome in
            ocrRunning = false
            switch outcome {
            case .text(let text): ocrResult = OCRPresenter.Result(clipID: clip.id, text: text)
            default: ocrNotice = outcome
            }
        }
    }

    func cancelExtractText() {
        if let id = clip.id { store.cancelOCR(for: id) }
    }

    /// Spinner scrim with Cancel while recognition runs.
    var ocrScrim: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Extracting text...").font(.callout).foregroundStyle(dsTokens.textPrimary)
            Button("Cancel") { cancelExtractText() }
        }
        .padding(20)
        .background(dsTokens.surfaceElevated, in: RoundedRectangle(cornerRadius: dsTokens.metrics.radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Extracting text")
    }

    /// Distinct notice / failure messages; failure keeps Retry.
    @ViewBuilder
    func ocrBanner(_ outcome: OCRExtractOutcome) -> some View {
        if case .failure(let message) = outcome {
            ClippyBanner(message, severity: .danger, actionTitle: "Retry", action: { extractText() }, dismiss: { ocrNotice = nil })
                .padding(6)
        } else {
            ClippyBanner(outcome.message, severity: .neutral, dismiss: { ocrNotice = nil }).padding(6)
        }
    }

    /// Explicit Copy / Paste taps in the result sheet.
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveOCRText(_ text: String) -> Bool {
        do {
            _ = try store.saveOCRText(text)
            return true
        } catch {
            ClippyLog.error("OCR save failed: \(error)", category: ClippyLog.storage)
            return false
        }
    }
}
