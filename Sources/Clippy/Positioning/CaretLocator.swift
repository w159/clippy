import AppKit
import ApplicationServices

/// Finds the screen rectangle of the text caret in whatever app has focus,
/// via the Accessibility API. This is what lets the panel open exactly where
/// the user is typing.
enum CaretLocator {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt when not yet trusted.
    @discardableResult
    static func requestPermission() -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Caret bounds in Cocoa screen coordinates (origin bottom-left), or nil
    /// when the focused app does not expose them (Electron hosts, some web
    /// views) or Accessibility permission is missing. Callers fall back to
    /// the mouse location.
    static func caretScreenRect() -> CGRect? {
        guard isTrusted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let focused = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &boundsRef
        ) == .success,
            let boundsRef,
            CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }

        // Electron and some web views report success with a zero/garbage rect.
        guard rect.origin != .zero || rect.size != .zero else { return nil }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }

        return convertToCocoaCoordinates(rect)
    }

    /// AX coordinates have their origin at the top-left of the primary
    /// screen; AppKit windows use bottom-left. The flip must use the global
    /// max-Y (the top of the union of all screen frames), not just the primary
    /// screen's height, otherwise carets on a secondary display above the
    /// primary convert to a Cocoa y in the wrong screen. We also prefer the
    /// screen whose frame actually contains the AX rect when one is found,
    /// which keeps the flip correct for unusual multi-monitor layouts.
    private static func convertToCocoaCoordinates(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }

        // Global max-Y in Cocoa (bottom-left) coordinates: the top edge of the
        // union of all screens. AX y=0 sits at this top edge and increases
        // downward, so cocoaY = globalMaxY - axY.
        let globalMaxY = screens.map { $0.frame.maxY }.max() ?? screens[0].frame.maxY
        return CGRect(
            x: rect.origin.x,
            y: globalMaxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
