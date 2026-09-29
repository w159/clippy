import AppKit
import CoreGraphics

/// Pure, deterministic image transforms for the image-clip editor. Each works on
/// the underlying CGImage so results are pixel-exact and unit-testable.
enum ImageEditing {
    /// The backing CGImage at full pixel resolution.
    static func cgImage(_ image: NSImage) -> CGImage? {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return rep.cgImage
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func image(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Rotate by a multiple of 90 degrees (clockwise positive). The canvas swaps
    /// width/height for odd multiples.
    static func rotated(_ image: NSImage, byDegrees degrees: Int) -> NSImage? {
        guard let cg = cgImage(image) else { return nil }
        let normalized = ((degrees % 360) + 360) % 360
        if normalized == 0 { return image }
        let swaps = normalized == 90 || normalized == 270
        let srcWidth = cg.width, srcHeight = cg.height
        let outWidth = swaps ? srcHeight : srcWidth
        let outHeight = swaps ? srcWidth : srcHeight
        guard let ctx = context(width: outWidth, height: outHeight) else { return nil }
        ctx.translateBy(x: CGFloat(outWidth) / 2, y: CGFloat(outHeight) / 2)
        // CGContext rotation is counter-clockwise; negate for clockwise input.
        ctx.rotate(by: -CGFloat(normalized) * .pi / 180)
        ctx.draw(cg, in: CGRect(x: -CGFloat(srcWidth) / 2, y: -CGFloat(srcHeight) / 2, width: CGFloat(srcWidth), height: CGFloat(srcHeight)))
        guard let out = ctx.makeImage() else { return nil }
        return self.image(from: out)
    }

    static func flipped(_ image: NSImage, horizontal: Bool) -> NSImage? {
        guard let cg = cgImage(image) else { return nil }
        let srcWidth = cg.width, srcHeight = cg.height
        guard let ctx = context(width: srcWidth, height: srcHeight) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(srcWidth), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(srcHeight))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(srcWidth), height: CGFloat(srcHeight)))
        guard let out = ctx.makeImage() else { return nil }
        return self.image(from: out)
    }

    /// Crop to a rectangle in image pixel coordinates (origin top-left). The rect
    /// is clamped to the image bounds; an empty intersection returns nil.
    static func cropped(_ image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cg = cgImage(image) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let clamped = rect.integral.intersection(bounds)
        guard !clamped.isEmpty, let out = cg.cropping(to: clamped) else { return nil }
        return self.image(from: out)
    }

    /// PNG bytes for saving an edited image back to the media store.
    static func pngData(_ image: NSImage) -> Data? {
        MediaStore.pngData(from: image)
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ).map {
            $0.interpolationQuality = .high
            return $0
        }
    }
}

/// Crop-selection geometry, kept in image pixel coordinates (origin top-left)
/// so a window resize never moves the selection over the picture. The canvas
/// draws the image scaled into a "fitted" size; these helpers convert between
/// that view space and pixel space.
enum CropSelection {
    /// Smallest selection edge, in view points, that counts as a selection.
    static let minimumEdge: CGFloat = 2

    /// Clamps a view-space point into `[0, fitted]`.
    static func clamp(_ point: CGPoint, to fitted: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), fitted.width), y: min(max(0, point.y), fitted.height))
    }

    /// Converts a view-space point to image pixels. Nil when the geometry is empty.
    static func imagePoint(fromView point: CGPoint, fitted: CGSize, pixels: CGSize) -> CGPoint? {
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let clamped = clamp(point, to: fitted)
        return CGPoint(x: clamped.x * pixels.width / fitted.width,
                       y: clamped.y * pixels.height / fitted.height)
    }

    /// The rectangle spanned by two image-space points, or nil when either
    /// edge is too small to be a deliberate selection at the current scale.
    static func imageRect(from start: CGPoint, to end: CGPoint, fitted: CGSize, pixels: CGSize) -> CGRect? {
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y))
        let scaleX = fitted.width / pixels.width
        let scaleY = fitted.height / pixels.height
        guard rect.width * scaleX > minimumEdge, rect.height * scaleY > minimumEdge else { return nil }
        return rect
    }

    /// Maps an image-space selection into the current fitted view space.
    static func viewRect(fromImage rect: CGRect, fitted: CGSize, pixels: CGSize) -> CGRect {
        guard pixels.width > 0, pixels.height > 0 else { return .zero }
        let sx = fitted.width / pixels.width
        let sy = fitted.height / pixels.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }
}
