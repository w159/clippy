import AppKit
import PDFKit

extension OCRService {
    /// Longest edge, in pixels, a scanned PDF page is rasterised at for Vision.
    static let pdfRenderPixelSize: CGFloat = 2048

    /// Extracts text from the first `OCRPreferences.pdfMaxPages` pages of the
    /// PDF at `url` (OCR-08). Pages with an embedded text layer use it directly;
    /// scanned pages are rasterised and recognised with Vision. Runs on the
    /// calling (background) thread.
    static func recognizePDF(at url: URL) -> RecognitionResult {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return .failure(OCRError.pdfLoadFailed(url))
        }
        return recognizePDF(document: document, maxPages: OCRPreferences.pdfMaxPages) { page in
            guard let image = renderPage(page) else { return nil }
            if case .success(let text) = performRecognition(cgImage: image) { return text }
            return nil
        }
    }

    /// Core PDF loop with an injectable scanned-page recogniser, so tests can
    /// exercise page selection and the text-layer preference without Vision.
    static func recognizePDF(
        document: PDFDocument, maxPages: Int, scannedPage: (PDFPage) -> String?
    ) -> RecognitionResult {
        var pages: [String] = []
        for index in 0..<min(document.pageCount, max(maxPages, 1)) {
            guard let page = document.page(at: index) else { continue }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !layer.isEmpty {
                pages.append(layer)
            } else if let scanned = scannedPage(page)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !scanned.isEmpty
            {
                pages.append(scanned)
            }
        }
        return .success(pages.joined(separator: "\n\n"))
    }

    /// Rasterises `page` on white, longest edge `pdfRenderPixelSize`.
    static func renderPage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = pdfRenderPixelSize / max(bounds.width, bounds.height)
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
