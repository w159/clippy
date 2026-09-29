import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum MediaStoreError: Error {
    case undecodableImage
    case thumbnailFailed
    case unreadableFile
}

/// Owns the on-disk directory for image clip payloads and thumbnails.
/// The database stores filenames only; the filename is the SHA-256 of the
/// PNG bytes, which makes storing the same image twice naturally idempotent.
final class MediaStore: Sendable {
    struct StoredImage: Equatable {
        let mediaFilename: String
        let thumbFilename: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteSize: Int
    }

    struct StoredFile: Equatable {
        let mediaFilename: String
        let byteSize: Int
        /// Set only when the stored file is a decodable image: a JPEG thumbnail
        /// plus its pixel dimensions, used by the file-clip card to show a real
        /// preview instead of a generic document glyph, and to unlock OCR
        /// (Extract Text) on file clips that happen to be images. Populated by a
        /// separate call to `imageThumbnail(forFileAt:hash:)`, not by `storeFile`
        /// itself, so copying a non-image file never pays the decode cost.
        var thumbFilename: String? = nil
        var pixelWidth: Int? = nil
        var pixelHeight: Int? = nil
    }

    let directory: URL
    private static let thumbnailMaxEdge: CGFloat = 400

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Directory name for sidecar data (capture flavors, sensitive flags) inside
    /// the media directory. `sweepOrphans` never touches it; sidecar files are
    /// keyed by `Clip.contentKey`, not by media filename, and pruned separately.
    static let sidecarDirectoryName = "_sidecar"

    /// Sidecar directory, created on first use.
    var sidecarDirectory: URL {
        let dir = directory.appendingPathComponent(Self.sidecarDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the image and a small thumbnail; both must exist before the
    /// caller commits a database row, so a row never references missing bytes.
    func store(pngData: Data) throws -> StoredImage {
        guard let rep = NSBitmapImageRep(data: pngData) else {
            throw MediaStoreError.undecodableImage
        }
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        let mediaFilename = "\(hash).png"
        let mediaURL = url(for: mediaFilename)
        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try pngData.write(to: mediaURL, options: .atomic)
        }
        // Alpha images get a PNG thumbnail (a JPEG has no alpha and rendered
        // transparent pixels black); opaque ones stay JPEG. Reuse whichever
        // already exists for this hash so a re-store is idempotent.
        let thumbFilename: String
        if FileManager.default.fileExists(atPath: url(for: "\(hash)-thumb.png").path) {
            thumbFilename = "\(hash)-thumb.png"
        } else if FileManager.default.fileExists(atPath: url(for: "\(hash)-thumb.jpg").path) {
            thumbFilename = "\(hash)-thumb.jpg"
        } else {
            let thumb = try Self.thumbnail(from: rep)
            thumbFilename = "\(hash)-thumb.\(thumb.isPNG ? "png" : "jpg")"
            try thumb.data.write(to: url(for: thumbFilename), options: .atomic)
        }
        return StoredImage(
            mediaFilename: mediaFilename,
            thumbFilename: thumbFilename,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            byteSize: pngData.count
        )
    }

    /// Copies the file at `sourceURL` into the media directory using a SHA-256
    /// content-hash filename so storing the same file twice is idempotent.
    /// The original extension is preserved (or omitted when absent) so the stored
    /// copy remains openable by UTType-aware apps.
    /// Throws `MediaStoreError.unreadableFile` when the source cannot be read.
    func storeFile(at sourceURL: URL) throws -> StoredFile {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw MediaStoreError.unreadableFile
        }
        guard !data.isEmpty else { throw MediaStoreError.unreadableFile }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = sourceURL.pathExtension
        let mediaFilename = ext.isEmpty ? hash : "\(hash).\(ext)"
        let destURL = url(for: mediaFilename)

        if !FileManager.default.fileExists(atPath: destURL.path) {
            try data.write(to: destURL, options: .atomic)
        }
        return StoredFile(mediaFilename: mediaFilename, byteSize: data.count)
    }

    /// Generates a thumbnail + pixel dimensions for an on-disk image file,
    /// keyed by the same content-hash `storeFile` already computed for it, so
    /// the thumbnail sits alongside the original bytes and is swept by the
    /// same eviction path (`evictOverCap`/`evictAbsoluteCeiling` already delete
    /// any referenced `thumbFilename` regardless of clip kind).
    ///
    /// Uses ImageIO's thumbnail generation directly from the source, so a
    /// large original (e.g. a multi-megapixel photo) is never fully decoded
    /// just to produce a small preview. Returns nil when the file is not a
    /// decodable image; callers should treat that as "not an image" rather
    /// than an error.
    func imageThumbnail(forFileAt fileURL: URL, hash: String) -> (
        thumbFilename: String, pixelWidth: Int, pixelHeight: Int
    )? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        for existing in ["\(hash)-thumb.png", "\(hash)-thumb.jpg"]
        where FileManager.default.fileExists(atPath: url(for: existing).path) {
            return (existing, pixelWidth, pixelHeight)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Int(Self.thumbnailMaxEdge),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
            let thumb = try? Self.encodeThumbnail(cgThumb)
        else { return nil }
        let thumbFilename = "\(hash)-thumb.\(thumb.isPNG ? "png" : "jpg")"
        do {
            try thumb.data.write(to: url(for: thumbFilename), options: .atomic)
        } catch {
            return nil
        }
        return (thumbFilename, pixelWidth, pixelHeight)
    }

    func delete(filenames: [String]) {
        for filename in filenames where !filename.isEmpty {
            try? FileManager.default.removeItem(at: url(for: filename))
        }
    }

    /// Removes files no clip references (leftovers from a crash between file
    /// write and row insert). Files younger than a minute are spared: they may
    /// belong to a capture whose database row is still in flight.
    func sweepOrphans(referencedFilenames: Set<String>) {
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for filename in onDisk where !referencedFilenames.contains(filename) && filename != Self.sidecarDirectoryName {
            let fileURL = url(for: filename)
            if let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                Date().timeIntervalSince(modified) < 60
            {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// PNG bytes for an image via the AppKit imaging stack. A Clippy-exported PNG
    /// passes through; other formats are normalized. Shared by clipboard capture
    /// and archive import, which each supply their own source-specific decode.
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// An encoded thumbnail and its container.
    struct EncodedThumbnail {
        let data: Data
        let isPNG: Bool
    }

    /// Aspect-fit thumbnail (never cropped) inside a `thumbnailMaxEdge` box.
    /// CGContext (not NSImage.lockFocus) so this is safe off the main thread;
    /// capture may run from background callers.
    private static func thumbnail(from rep: NSBitmapImageRep) throws -> EncodedThumbnail {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0, let cgImage = rep.cgImage else {
            throw MediaStoreError.thumbnailFailed
        }
        return try encodeThumbnail(cgImage)
    }

    /// Scales `cgImage` to fit the thumbnail box (never upscaling) and encodes it:
    /// PNG when the image carries alpha, JPEG over a white background otherwise.
    static func encodeThumbnail(_ cgImage: CGImage) throws -> EncodedThumbnail {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { throw MediaStoreError.thumbnailFailed }
        let scale = min(1, thumbnailMaxEdge / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw MediaStoreError.thumbnailFailed }
        context.interpolationQuality = .high
        let hasAlpha = imageHasAlpha(cgImage)
        if !hasAlpha {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { throw MediaStoreError.thumbnailFailed }
        let rep = NSBitmapImageRep(cgImage: scaled)
        let encoded = hasAlpha
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        guard let data = encoded else { throw MediaStoreError.thumbnailFailed }
        return EncodedThumbnail(data: data, isPNG: hasAlpha)
    }

    /// True when the image has an alpha channel that is not entirely opaque
    /// padding (`noneSkip*` and `none` are opaque).
    static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: - Encoded-data decoding (OCR-06)

    /// PNG bytes for any ImageIO-decodable data (JPEG, HEIC, TIFF, GIF, PNG...),
    /// decoded straight from the encoded bytes with no NSImage/TIFF round trip.
    /// PNG input passes through untouched, so the stored file is byte-identical
    /// to what the source app put on the pasteboard.
    static func pngData(fromEncoded data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// PNG of the first page of PDF data, longest edge at most `maxEdge` pixels.
    /// PDF-only pasteboards (vector copies from Preview, Illustrator) become an
    /// image clip this way; the PDF itself is kept as a restorable flavor.
    static func pngData(fromPDF data: Data, maxEdge: CGFloat = 2048) -> Data? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxEdge / max(bounds.width, bounds.height), 4)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = page.thumbnail(of: size, for: .mediaBox)
        return pngData(from: image)
    }
}
