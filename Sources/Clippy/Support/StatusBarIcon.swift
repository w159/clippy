import AppKit

// The menu bar icon: the system `paperclip` SF Symbol. Rendered with a text-style
// symbol configuration so the system picks the correct optical weight/scale for
// the menu bar, and centered in an image sized to the status button so it
// cannot read as top-cropped. The paused state overlays a diagonal slash to
// show capture is off.
enum StatusBarIcon {
    /// The paperclip symbol as a template image, centered in a square canvas
    /// the height of the menu bar button so the glyph is vertically aligned.
    /// `paused` adds a slash overlay.
    static func image(paused: Bool = false) -> NSImage {
        // Use a text-style configuration so AppKit sizes the symbol for the menu
        // bar context (correct optical weight and baseline), rather than a fixed
        // pointSize that can read as top-cropped inside the button.
        let config = NSImage.SymbolConfiguration(textStyle: .body, scale: .small)
        let raw = NSImage(systemSymbolName: "paperclip",
                          accessibilityDescription: paused ? "Clippy (paused)" : "Clippy")?
            .withSymbolConfiguration(config) ?? NSImage()

        // Center the glyph in a canvas the height of a status bar button so the
        // symbol is vertically centered, not pinned to the top of its bbox.
        let canvas = CGSize(width: 22, height: 22)
        let centered = NSImage(size: canvas, flipped: false) { rect in
            let drawRect = NSRect(
                x: (rect.width - raw.size.width) / 2,
                y: (rect.height - raw.size.height) / 2,
                width: raw.size.width,
                height: raw.size.height
            )
            raw.draw(in: drawRect)
            return true
        }
        centered.isTemplate = true
        guard !paused else { return Self.applySlash(to: centered, canvas: canvas) }
        return centered
    }

    /// Paused: draw the symbol and a diagonal slash across it.
    private static func applySlash(to symbol: NSImage, canvas: CGSize) -> NSImage {
        let slashed = NSImage(size: canvas, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.black.set()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.16))
            slash.line(to: NSPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.16))
            slash.lineWidth = max(1.4, rect.width * 0.11)
            slash.lineCapStyle = .round
            slash.stroke()
            return true
        }
        slashed.isTemplate = true
        return slashed
    }

    /// Squash-and-stretch hop on the status button, pivoting at its center.
    /// Called in sync with the capture sound so icon and sound fire together.
    static func bounce(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        // Do NOT clip the layer bounds: the bounce overshoot (1.14x) is meant to
        // extend past the button's resting frame, and masksToBounds would crop
        // the top of the paperclip exactly the way the audit reported. The icon
        // always snaps back to its resting spot via isRemovedOnCompletion.
        guard let layer = button.layer else { return }
        layer.masksToBounds = false

        // Scale about the button's center by baking the pivot into the transform
        // matrix (translate to center, scale, translate back). The layer's model
        // `position`/`anchorPoint` are left untouched, and the animation is removed
        // on completion, so the icon always snaps back to its resting spot. An
        // earlier version mutated `position`, which permanently shifted the icon up.
        let cx = button.bounds.midX, cy = button.bounds.midY
        func scale(_ s: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            return NSValue(caTransform3D: t)
        }

        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = [scale(1.0), scale(0.82), scale(1.14), scale(0.96), scale(1.0)]
        bounce.keyTimes = [0, 0.28, 0.6, 0.82, 1.0]
        bounce.duration = 0.34
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bounce.isRemovedOnCompletion = true
        layer.add(bounce, forKey: "captureBounce")
    }
}
