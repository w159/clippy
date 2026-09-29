import Foundation

/// Sequential text extraction over many files with progress (OCR-08). Store-free:
/// callers decide what to do with the results.
enum OCRBatch {
    /// One file's outcome.
    struct Item {
        let url: URL
        let result: OCRService.RecognitionResult
    }

    /// Cancellation handle; `cancel()` stops before the next file starts.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// Recognizer seam: same contract as `OCRService.recognizeText` (completion
    /// on the main queue).
    typealias Recognizer = (URL, @escaping @MainActor (OCRService.RecognitionResult) -> Void) -> Void

    /// Recognize `urls` one after another. Runs on the main actor.
    /// - Parameters:
    ///   - progress: `(completed, total, url just finished)` on the main queue.
    ///   - completion: all items processed so far (fewer than `urls.count` when
    ///     cancelled), on the main queue.
    /// - Returns: handle to cancel the run.
    @MainActor @discardableResult
    static func run(
        urls: [URL],
        recognizer: @escaping Recognizer = { OCRService.recognizeText(in: $0, completion: $1) },
        progress: ((Int, Int, URL) -> Void)? = nil,
        completion: @escaping ([Item]) -> Void
    ) -> Handle {
        let handle = Handle()
        Run(urls: urls, recognizer: recognizer, progress: progress, completion: completion, handle: handle).next(0)
        return handle
    }

    /// One in-flight batch: the recognizer's completion chains to the next file,
    /// so the accumulated state lives in a main-actor object rather than in
    /// captured local variables.
    @MainActor
    private final class Run {
        let urls: [URL]
        let recognizer: Recognizer
        let progress: ((Int, Int, URL) -> Void)?
        let completion: ([Item]) -> Void
        let handle: Handle
        var items: [Item] = []

        init(urls: [URL], recognizer: @escaping Recognizer, progress: ((Int, Int, URL) -> Void)?,
             completion: @escaping ([Item]) -> Void, handle: Handle) {
            self.urls = urls
            self.recognizer = recognizer
            self.progress = progress
            self.completion = completion
            self.handle = handle
        }

        func next(_ index: Int) {
            guard index < urls.count, !handle.isCancelled else {
                completion(items)
                return
            }
            let url = urls[index]
            recognizer(url) { result in
                self.items.append(Item(url: url, result: result))
                self.progress?(self.items.count, self.urls.count, url)
                self.next(index + 1)
            }
        }
    }
}
