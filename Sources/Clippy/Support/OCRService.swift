import AppKit
import Vision

/// Runs Vision text recognition on an image file and returns the joined
/// recognized strings. Uses accurate-level recognition with automatic language
/// detection and language correction enabled.
///
/// All work runs on a background queue; the completion is delivered on the
/// main queue so callers can update UI directly.
enum OCRService {

    // MARK: - Public API

    /// Recognized text result. `text` is nil only on a hard Vision failure;
    /// empty-string means Vision ran successfully but found no text.
    enum RecognitionResult {
        case success(String)
        case failure(Error)
    }

    /// Recognize text in the image at `imageURL`.
    /// - Parameters:
    ///   - imageURL: File URL of any image Vision can decode (PNG, JPEG, etc.).
    ///   - completion: Called on the **main queue** with the result.
    static func recognizeText(
        in imageURL: URL,
        completion: @escaping (RecognitionResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performRecognition(imageURL: imageURL)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Warm-Up

    /// True while a warm-up recognition is in flight; guarded by `warmUpLock`
    /// so concurrent callers collapse instead of stacking cold model loads.
    private nonisolated(unsafe) static var isWarming = false
    private nonisolated(unsafe) static let warmUpLock = NSLock()

    /// Warms the Vision text-recognition stack in the background.
    ///
    /// The **first** VNRecognizeTextRequest after the models have gone cold
    /// pays a one-time model load (measured ~24s on current macOS; the OS
    /// re-evicts them after a period of disuse); every later request is
    /// ~0.03s. Paying that cost invisibly on a utility queue — at launch and
    /// whenever the panel is shown, the user's "about to interact" signal —
    /// means Extract Text completes in ~0.03s instead of appearing hung.
    /// Fire-and-forget: never touches the main thread, allocates no files.
    /// Concurrent calls collapse into the in-flight one.
    static func warmUp() {
        guard warmUpLock.withLock({
            if isWarming { return false }
            isWarming = true
            return true
        }) else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { warmUpLock.withLock { isWarming = false } }
            // Tiny opaque white in-memory image (no disk I/O): enough to make
            // Vision load its model, too small to matter for recognition cost.
            let size = CGSize(width: 64, height: 32)
            guard let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            guard let cgImage = context.makeImage() else { return }
            let startedAt = Date()
            _ = performRecognition(cgImage: cgImage)
            ClippyLog.info(
                "Vision OCR warm-up finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s",
                category: ClippyLog.lifecycle)
        }
    }

    // MARK: - Implementation

    private static func performRecognition(imageURL: URL) -> RecognitionResult {
        guard let cgImage = loadCGImage(from: imageURL) else {
            return .failure(OCRError.imageLoadFailed(imageURL))
        }

        return performRecognition(cgImage: cgImage)
    }

    /// Runs the recognition request/handler/results logic on an in-memory
    /// CGImage; the core shared by the URL wrapper and `warmUp()`.
    private static func performRecognition(cgImage: CGImage) -> RecognitionResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Automatic language detection: pass an empty array so Vision picks
        // all supported languages rather than filtering to a fixed set.
        request.recognitionLanguages = []

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(error)
        }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return .success(lines.joined(separator: "\n"))
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}

// MARK: - Errors

enum OCRError: LocalizedError {
    case imageLoadFailed(URL)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Could not load image for text recognition: \(url.lastPathComponent)"
        }
    }
}
