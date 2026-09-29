import AppKit
import os
import Vision

/// Runs Vision text recognition on an image or PDF file and returns the joined
/// recognized strings. Level and languages come from `OCRPreferences`; on
/// macOS 26 document recognition (paragraphs, tables) is used when enabled and
/// available, with line recognition as the fallback. PDFs are handled in
/// `OCRService+PDF.swift`.
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
        completion: @escaping @MainActor (RecognitionResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = imageURL.pathExtension.lowercased() == "pdf"
                ? recognizePDF(at: imageURL)
                : performRecognition(imageURL: imageURL)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    // MARK: - Warm-Up

    /// True while a warm-up recognition is in flight; the lock makes concurrent
    /// callers collapse instead of stacking cold model loads.
    private static let isWarming = OSAllocatedUnfairLock(initialState: false)

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
        guard isWarming.withLock({ warming in
            if warming { return false }
            warming = true
            return true
        }) else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { isWarming.withLock { $0 = false } }
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
            _ = performRecognition(cgImage: cgImage, allowDocuments: false)
            ClippyLog.info(
                "Vision OCR warm-up finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s",
                category: ClippyLog.lifecycle)
        }
    }

    // MARK: - Implementation

    static func performRecognition(imageURL: URL) -> RecognitionResult {
        guard let cgImage = loadCGImage(from: imageURL) else {
            return .failure(OCRError.imageLoadFailed(imageURL))
        }

        return performRecognition(cgImage: cgImage)
    }

    /// Runs the recognition request/handler/results logic on an in-memory
    /// CGImage; the core shared by the URL wrapper and `warmUp()`.
    static func performRecognition(cgImage: CGImage, allowDocuments: Bool = true) -> RecognitionResult {
        if allowDocuments, OCRPreferences.useDocumentRecognition, #available(macOS 26.0, *),
            let text = recognizeDocumentText(cgImage: cgImage)
        {
            return .success(text)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = OCRPreferences.level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        // Language: the user's setting (OCRPreferences.languages) when
        // present; otherwise Vision detects the language automatically (OCR-12).
        let languages = OCRPreferences.languages
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
            request.automaticallyDetectsLanguage = false
        }

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

    /// Longest edge, in pixels, an image is decoded at for OCR. Text stays
    /// legible well below this; decoding a 100-megapixel bitmap at full size only
    /// costs memory (OCR-06).
    static let maxDecodePixelSize = 4096

    /// Decodes at most `maxDecodePixelSize` on the long edge straight from the
    /// encoded file via ImageIO, applying EXIF orientation, so a huge image is
    /// never fully decoded.
    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Never upscale: cap at the image's own long edge when it is smaller.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longEdge = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let target = longEdge > 0 ? min(longEdge, maxDecodePixelSize) : maxDecodePixelSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Errors

enum OCRError: LocalizedError {
    case imageLoadFailed(URL)
    case pdfLoadFailed(URL)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Could not load image for text recognition: \(url.lastPathComponent)"
        case .pdfLoadFailed(let url):
            return "Could not open PDF for text recognition: \(url.lastPathComponent)"
        }
    }
}
