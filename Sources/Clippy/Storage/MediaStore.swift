import AppKit
import CryptoKit
import Foundation

enum MediaStoreError: Error {
    case undecodableImage
    case thumbnailFailed
    case unreadableFile
}

/// Owns the on-disk directory for image clip payloads and thumbnails.
/// The database stores filenames only; the filename is the SHA-256 of the
/// PNG bytes, which makes storing the same image twice naturally idempotent.
final class MediaStore {
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

    /// Writes the image and a small thumbnail; both must exist before the
    /// caller commits a database row, so a row never references missing bytes.
    func store(pngData: Data) throws -> StoredImage {
        guard let rep = NSBitmapImageRep(data: pngData) else {
            throw MediaStoreError.undecodableImage
        }
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        let mediaFilename = "\(hash).png"
        let thumbFilename = "\(hash)-thumb.jpg"
        let mediaURL = url(for: mediaFilename)
        let thumbURL = url(for: thumbFilename)
        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try pngData.write(to: mediaURL, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: thumbURL.path) {
            try Self.thumbnailJPEG(from: rep).write(to: thumbURL, options: .atomic)
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

        let thumbFilename = "\(hash)-thumb.jpg"
        let thumbURL = url(for: thumbFilename)
        if !FileManager.default.fileExists(atPath: thumbURL.path) {
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: Int(Self.thumbnailMaxEdge),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
                let jpeg = NSBitmapImageRep(cgImage: cgThumb)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return nil }
            do {
                try jpeg.write(to: thumbURL, options: .atomic)
            } catch {
                return nil
            }
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
        for filename in onDisk where !referencedFilenames.contains(filename) {
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

    /// CGContext (not NSImage.lockFocus) so this is safe off the main thread;
    /// capture may run from background callers.
    private static func thumbnailJPEG(from rep: NSBitmapImageRep) throws -> Data {
        let width = CGFloat(rep.pixelsWide)
        let height = CGFloat(rep.pixelsHigh)
        guard width > 0, height > 0, let cgImage = rep.cgImage else {
            throw MediaStoreError.thumbnailFailed
        }
        let scale = min(1, thumbnailMaxEdge / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))
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
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { throw MediaStoreError.thumbnailFailed }
        guard
            let jpeg = NSBitmapImageRep(cgImage: scaled)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw MediaStoreError.thumbnailFailed }
        return jpeg
    }
}
