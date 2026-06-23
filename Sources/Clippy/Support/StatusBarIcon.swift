import AppKit

// The menu bar icon: the system `paperclip` SF Symbol as a template image. The
// paused state overlays a diagonal slash to show capture is off.
//
// Sizing: a standalone menu bar glyph uses the point-size configuration
// `init(pointSize:weight:scale:)` (see Apple's NSImage.SymbolConfiguration docs:
// scale variants are defined relative to the SF font's cap height, and the
// default scale is .medium). A text-style configuration (`init(textStyle:scale:)`)
// is for symbols sitting inline with Dynamic Type text; pairing it with
// `.small` shrinks the glyph to the small cap-height variant, which is what
// previously made the menu bar paperclip read at roughly half size. The status
// button centers a template image itself, so no manual canvas sizing is needed;
// the earlier top-crop was the bounce animation's masksToBounds, fixed below.
enum StatusBarIcon {
    /// The paperclip symbol as a template image. `paused` adds a slash overlay.
    static func image(paused: Bool = false) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular, scale: .medium)
        let symbol = NSImage(systemSymbolName: "paperclip",
                             accessibilityDescription: paused ? "Clippy (paused)" : "Clippy")?
            .withSymbolConfiguration(config) ?? NSImage()
        symbol.isTemplate = true
        guard paused else { return symbol }
        return Self.applySlash(to: symbol)
    }

    /// Paused: draw the symbol and a diagonal slash across it, in a canvas the
    /// size of the symbol itself so the paused glyph matches the active one.
    private static func applySlash(to symbol: NSImage) -> NSImage {
        let slashed = NSImage(size: symbol.size, flipped: false) { rect in
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
