import AppKit
import SwiftUI

/// Resolves source-app bundle ids to their real icons and to a dominant
/// color derived from the icon, which drives per-app card tinting (the
/// Paste-style look). Everything is cached; icon lookups and pixel
/// averaging only happen once per app.
@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()

    private var iconCache: [String: NSImage] = [:]
    private var colorCache: [String: NSColor] = [:]
    private var missingBundleIDs: Set<String> = []

    private init() {}

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !missingBundleIDs.contains(bundleID) else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingBundleIDs.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 32, height: 32)
        iconCache[bundleID] = icon
        return icon
    }

    func dominantColor(forBundleID bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let cached = colorCache[bundleID] { return Color(nsColor: cached) }
        guard let icon = icon(forBundleID: bundleID),
              let averaged = Self.averageColor(of: icon)
        else { return nil }
        colorCache[bundleID] = averaged
        return Color(nsColor: averaged)
    }

    /// Average of the icon's opaque pixels, then normalized into a band
    /// that works as a tint in both light and dark mode: enough saturation
    /// to read as a color, brightness clamped away from white and black.
    private static func averageColor(of image: NSImage) -> NSColor? {
        let side = 8
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in 0..<side {
            for x in 0..<side {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.3 else { continue }
                red += pixel.redComponent
                green += pixel.greenComponent
                blue += pixel.blueComponent
                count += 1
            }
        }
        guard count > 0 else { return nil }

        let averaged = NSColor(
            red: red / count,
            green: green / count,
            blue: blue / count,
            alpha: 1
        )
        guard let rgb = averaged.usingColorSpace(.deviceRGB) else { return averaged }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(max(saturation * 1.4, 0.40), 0.85),
            brightness: min(max(brightness, 0.55), 0.85),
            alpha: 1
        )
    }
}
