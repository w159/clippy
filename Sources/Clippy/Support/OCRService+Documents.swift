import CoreGraphics
import Foundation
import Vision

extension OCRService {
    /// Recognizes `cgImage` with the macOS 26 `RecognizeDocumentsRequest` and
    /// renders paragraphs and tables as text. Returns nil on any failure or when
    /// nothing is found so the caller falls back to line recognition.
    ///
    /// Blocks the calling (background) thread; never call from the main thread.
    @available(macOS 26.0, *)
    static func recognizeDocumentText(cgImage: CGImage) -> String? {
        var request = RecognizeDocumentsRequest()
        let languages = OCRPreferences.languages
        request.textRecognitionOptions.useLanguageCorrection = true
        if languages.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            request.textRecognitionOptions.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        }
        request.barcodeDetectionOptions.enabled = false

        let box = DocumentResultBox()
        let done = DispatchSemaphore(value: 0)
        let frozen = request
        Task.detached(priority: .userInitiated) {
            do {
                let observations = try await frozen.perform(on: cgImage)
                box.text = documentText(from: observations)
            } catch {
                ClippyLog.info("Document OCR unavailable, falling back: \(error)", category: ClippyLog.storage)
            }
            done.signal()
        }
        done.wait()
        guard let text = box.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Paragraph/table rendering: paragraphs separated by blank lines, table
    /// rows as tab-separated cells (pasteable into spreadsheets).
    @available(macOS 26.0, *)
    static func documentText(from observations: [DocumentObservation]) -> String {
        observations.map { observation in
            let container = observation.document
            var blocks: [String] = []
            if let title = container.title?.transcript, !title.isEmpty { blocks.append(title) }
            let paragraphs = container.paragraphs.map(\.transcript).filter { !$0.isEmpty }
            blocks.append(contentsOf: paragraphs.isEmpty ? [container.text.transcript] : paragraphs)
            for table in container.tables {
                let rows = table.rows.map { row in
                    row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: "\t")
                }
                blocks.append(rows.joined(separator: "\n"))
            }
            return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }
}

/// Carries the async result across the semaphore hand-off.
private final class DocumentResultBox: @unchecked Sendable {
    var text: String?
}
