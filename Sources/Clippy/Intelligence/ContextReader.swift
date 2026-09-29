import AppKit
import ApplicationServices

/// Reads the frontmost app's focused element through Accessibility.
/// Nothing read here is logged or persisted.
enum ContextReader {
    /// AX messaging timeout applied to every element we touch.
    private static let axTimeout: Float = 0.25

    /// Reads the FRONTMOST app's focused element via AXUIElement. Returns nil when: AX not trusted,
    /// frontmost app is Clippy itself or in `ignoredBundleIDs`, or the focused element is a secure
    /// text field (role/subrole AXSecureTextField). Never blocks longer than ~250ms per AX call.
    /// Call from a background queue.
    static func capture(ignoredBundleIDs: Set<String>, maxChars: Int) -> ScreenContext? {
        let started = Date()
        let front = NSWorkspace.shared.frontmostApplication
        let context = read(ignoredBundleIDs: ignoredBundleIDs, maxChars: maxChars)
        ContextCaptureLog.shared.record(
            appName: context?.appName ?? front?.localizedName, bundleID: front?.bundleIdentifier,
            textCharacters: context?.text.count, elapsed: Date().timeIntervalSince(started))
        return context
    }

    private static func read(ignoredBundleIDs: Set<String>, maxChars: Int) -> ScreenContext? {
        guard CaretLocator.isTrusted,
            let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let bundleID = app.bundleIdentifier
        if let bundleID {
            if bundleID == Bundle.main.bundleIdentifier || ignoredBundleIDs.contains(bundleID) {
                return nil
            }
        } else if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        // INT-08: skip hosts that keep hitting the AX timeout; time every other read.
        let stats = ContextReaderStats.shared
        if let bundleID, stats.shouldSkip(bundleID: bundleID) { return nil }
        let started = Date()
        defer {
            if let bundleID { stats.record(bundleID: bundleID, elapsed: Date().timeIntervalSince(started)) }
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        var context = ScreenContext(appName: app.localizedName, bundleID: bundleID, text: "")

        if let window = element(appElement, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(window, axTimeout)
            context.windowTitle = string(window, kAXTitleAttribute)
            context.documentURL = string(window, kAXDocumentAttribute)
        }

        if let focused = element(appElement, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, axTimeout)
            let role = string(focused, kAXRoleAttribute)
            let subrole = string(focused, kAXSubroleAttribute)
            let secure = "AXSecureTextField"
            if role == secure || subrole == secure { return nil }
            context.text = focusedText(focused, maxChars: maxChars)
        }

        context.capturedAt = Date()
        return context
    }

    // MARK: - Attribute helpers

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
            let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        // Type ID verified above, so the downcast cannot fail.
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        if let text = ref as? String { return text }
        if let url = ref as? URL { return url.absoluteString }
        return nil
    }

    /// Selected text when present, else up to `maxChars` characters ending at
    /// the caret (or the tail of the value when no caret range is exposed).
    private static func focusedText(_ focused: AXUIElement, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        if let selected = string(focused, kAXSelectedTextAttribute),
            !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return String(selected.prefix(maxChars))
        }
        guard let value = string(focused, kAXValueAttribute), !value.isEmpty else { return "" }
        let chars = Array(value)
        if chars.count <= maxChars { return value }

        var end = chars.count
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(rangeRef, to: AXValue.self), .cfRange, &range), range.location >= 0 {
                // AX offsets are UTF-16; map to a Character offset.
                let utf16 = value.utf16
                let clamped = min(range.location, utf16.count)
                if let idx = utf16.index(utf16.startIndex, offsetBy: clamped, limitedBy: utf16.endIndex),
                    let charIdx = idx.samePosition(in: value)
                {
                    end = value.distance(from: value.startIndex, to: charIdx)
                }
            }
        }
        let start = max(0, end - maxChars)
        return String(chars[start..<end])
    }
}
