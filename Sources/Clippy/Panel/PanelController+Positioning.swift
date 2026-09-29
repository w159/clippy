import AppKit
import Combine
import SwiftUI

// MARK: - Positioning

extension PanelController {
    /// Pure placement guard: never shift a panel after the pointer moved,
    /// the user interacted, or the AX result would cause a visible jump.
    static func shouldApplyCaretPlacement(
        initialFrame: CGRect,
        caretFrame: CGRect,
        initialMouse: CGPoint,
        currentMouse: CGPoint,
        interactionUnchanged: Bool
    ) -> Bool {
        guard interactionUnchanged else { return false }
        let mouseDelta = hypot(currentMouse.x - initialMouse.x, currentMouse.y - initialMouse.y)
        let frameDelta = hypot(caretFrame.minX - initialFrame.minX, caretFrame.minY - initialFrame.minY)
        return mouseDelta <= 4 && frameDelta <= 32
    }

    /// Immediate fallback frame for every mode. Never calls AX; every branch
    /// is clamped to the visible screen area.
    func fastFrame(size: NSSize) -> NSRect {
        switch settings.positionMode {
        case .caret, .mouse:
            // Caret mode uses an immediate mouse anchor; a background AX result
            // may refine it only when movement is negligible.
            return frame(anchoredTo: mouseAnchor(), size: size)
        case .lastPosition:
            let screen = screen(containing: NSEvent.mouseLocation)
            if let display = PanelDisplayMemory.displayID(of: screen),
               let origin = displayMemory.origin(for: display) {
                return clamped(NSRect(origin: origin, size: size), within: screen.visibleFrame)
            }
            if let origin = settings.lastPanelOrigin {
                return clamped(NSRect(origin: origin, size: size))
            }
            return centeredFrame(size: size)
        case .screenCenter:
            return centeredFrame(size: size)
        }
    }

    /// PNL-06: displays were added, removed or rearranged. Forget origins for
    /// displays that are gone and pull a visible panel back on screen.
    func screenParametersChanged() {
        let connected = Set(NSScreen.screens.compactMap(PanelDisplayMemory.displayID(of:)))
        displayMemory.prune(keeping: connected)
        guard let panel, panel.isVisible else { return }
        let target = clamped(panel.frame)
        if target != panel.frame { panel.setFrame(target, display: true, animate: false) }
    }

    func mouseAnchor() -> CGRect {
        let location = NSEvent.mouseLocation
        return CGRect(x: location.x, y: location.y, width: 0, height: 0)
    }

    /// Place the panel just below the anchor rect; flip above it when there
    /// is no room, and keep everything inside the screen's visible frame.
    func frame(anchoredTo anchor: CGRect, size: NSSize) -> NSRect {
        let visible = screen(containing: anchor.origin).visibleFrame
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - 6 - size.height)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 6
        }
        return clamped(NSRect(origin: origin, size: size), within: visible)
    }

    func centeredFrame(size: NSSize) -> NSRect {
        let visible = screen(containing: NSEvent.mouseLocation).visibleFrame
        return clamped(NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), within: visible)
    }

    /// Fits `rect` on screen. A panel taller or wider than the screen is shrunk to
    /// fit (top edge stays visible) instead of pinning its bottom edge off-screen.
    func clamped(_ rect: NSRect, within visible: NSRect? = nil) -> NSRect {
        let bounds = visible ?? (screenContaining(rect: rect) ?? screen(containing: rect.origin)).visibleFrame
        return PanelGeometry.clamp(rect, within: bounds)
    }

    /// The screen sharing the most area with `rect`, nil when it is fully off all screens.
    func screenContaining(rect: NSRect) -> NSScreen? {
        // Explicit loop: the chained map/filter/max closure was too complex for
        // the type-checker.
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let overlap = candidate.frame.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = candidate
            }
        }
        return best
    }

    func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen.main!
    }
}
