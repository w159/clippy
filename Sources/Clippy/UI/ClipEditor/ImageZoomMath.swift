import CoreGraphics
import Foundation

/// Zoom arithmetic for the image editor canvas (EDT-08).
enum ImageZoomMath {
    static let minimumScale: CGFloat = 0.05
    static let maximumScale: CGFloat = 8
    /// Multiplicative step for the -/+ buttons.
    static let step: CGFloat = 1.25

    /// Scale that fits `image` inside `viewport` without upscaling past 100%.
    /// Zero for an empty image or viewport.
    static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 0 }
        return min(viewport.width / image.width, viewport.height / image.height, 1)
    }

    /// Clamps a requested scale into the supported range.
    static func clamp(_ scale: CGFloat) -> CGFloat { min(maximumScale, max(minimumScale, scale)) }

    static func zoomedIn(from scale: CGFloat) -> CGFloat { clamp(scale * step) }
    static func zoomedOut(from scale: CGFloat) -> CGFloat { clamp(scale / step) }

    /// On-screen size of `image` at `scale`.
    static func displaySize(image: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// "100%" style label.
    static func percentLabel(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }
}
