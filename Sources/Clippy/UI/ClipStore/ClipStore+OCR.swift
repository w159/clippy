import Combine
import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Outcome of an Extract Text run (OCR-01). Extraction NEVER touches the
/// pasteboard or database: recognized text is returned for the UI to present,
/// and the user chooses Copy, Save as clip or Paste explicitly.
enum OCRExtractOutcome: Equatable {
    /// Recognized, non-empty text.
    case text(String)
    /// Neutral outcome (no text, cancelled, already running, image deleted).
    case notice(String)
    /// Recognition or setup failed.
    case failure(String)

    /// Human-readable message for banners.
    var message: String {
        switch self {
        case .text: return "Text extracted."
        case .notice(let message), .failure(let message): return message
        }
    }
}

/// Per-clip OCR state (OCR-05). One tiny observable per clip id, so a card that
/// observes only its own `OCRProgress` re-renders when ITS extraction starts or
/// finishes, not every card in the list (which is what the store-wide
/// `ocrInFlightClipIDs` set forces).
final class OCRProgress: ObservableObject {
    @Published fileprivate(set) var isRunning = false
}

extension ClipStore {
    /// The observable OCR state for `clipID`, created on first use. Main thread.
    func ocrProgress(for clipID: Int64) -> OCRProgress {
        if let existing = ocrProgressByClip[clipID] { return existing }
        let created = OCRProgress()
        ocrProgressByClip[clipID] = created
        return created
    }

    /// Whether an extraction for `clipID` is running.
    func isOCRRunning(for clipID: Int64) -> Bool { ocrRunTokens[clipID] != nil }

    /// Cancel a running extraction. Vision cannot be interrupted, but the run's
    /// token is revoked, so its result is discarded: nothing is presented,
    /// and the completion reports the cancellation.
    func cancelOCR(for clipID: Int64) {
        guard ocrRunTokens[clipID] != nil else { return }
        ocrRunTokens[clipID] = nil
        setOCRRunning(false, for: clipID)
    }

    private func setOCRRunning(_ running: Bool, for clipID: Int64) {
        if running { ocrInFlightClipIDs.insert(clipID) } else { ocrInFlightClipIDs.remove(clipID) }
        let progress = ocrProgress(for: clipID)
        if progress.isRunning != running { progress.isRunning = running }
        if !running { ocrProgressByClip[clipID] = nil }
    }

    /// Run OCR on an image clip (or a file clip detected as an image during
    /// capture, see `Clip.isImageLike`) and hand the recognized text to
    /// `completion` (always on the main queue). Nothing is written to the
    /// pasteboard or the database; see `saveOCRText(_:)`.
    func extractText(from clip: Clip, completion: @escaping (OCRExtractOutcome) -> Void) {
        guard clip.isImageLike, let imageURL = imageURL(for: clip) else {
            completion(.failure("No image data for this clip."))
            return
        }
        let clipID = clip.id
        if let clipID, ocrRunTokens[clipID] != nil {
            completion(.notice("Text extraction is already running for this clip."))
            return
        }
        // A clip with no identity (never persisted) cannot be tracked;
        // run it untracked rather than refusing it as a false duplicate.
        let runToken = UUID()
        if let clipID {
            ocrRunTokens[clipID] = runToken
            setOCRRunning(true, for: clipID)
        }
        ClippyLog.info("OCR started for clip \(clipID.map(String.init) ?? "nil")", category: ClippyLog.storage)
        let startedAt = Date()
        recognizer(imageURL) { [weak self] result in
            guard let self else { return }
            // Cancelled (or superseded) while Vision ran: present nothing.
            if let clipID {
                guard self.ocrRunTokens[clipID] == runToken else {
                    completion(.notice("Text extraction was cancelled."))
                    return
                }
                self.ocrRunTokens[clipID] = nil
                self.setOCRRunning(false, for: clipID)
            }
            let secs = String(format: "%.2f", Date().timeIntervalSince(startedAt))
            switch result {
            case .success(let raw):
                // Whitespace-only output is "no text", not a success.
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    ClippyLog.info("OCR finished in \(secs)s: empty", category: ClippyLog.storage)
                    completion(.notice("No text found in image."))
                    return
                }
                ClippyLog.info("OCR finished in \(secs)s: \(text.count) chars", category: ClippyLog.storage)
                // The source image may have been deleted while OCR ran; do not
                // resurrect derived text for it.
                if let clipID, (try? self.database.clipExists(id: clipID)) != true {
                    completion(.notice("The image was deleted before text extraction finished."))
                    return
                }
                completion(.text(text))
            case .failure(let error):
                ClippyLog.error("OCR failed after \(secs)s: \(error)", category: ClippyLog.storage)
                completion(.failure("Text extraction failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Saves recognized text as a new text clip ("Save as clip"). The user
    /// action is explicit; the pasteboard is not touched.
    @discardableResult
    func saveOCRText(_ text: String) throws -> Int64 {
        try database.insertTextClip(text, sourceAppName: "Clippy OCR")
    }
}
