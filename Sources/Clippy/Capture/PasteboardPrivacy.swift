import AppKit

/// Awareness of the macOS 15.4+ pasteboard privacy controls (PLT-09).
/// `NSPasteboard.accessBehavior` and `detectPatterns` exist in the 15.4 SDK;
/// enforcement on later releases is unconfirmed, so this only reports state and
/// never changes what Clippy reads unless the user has explicitly denied access.
enum PasteboardPrivacy {
    enum Access: Equatable {
        /// Reading is allowed (or the OS predates the controls).
        case allowed
        /// The system will ask the user on read.
        case ask
        /// The user denied this app; reads return nothing.
        case denied
    }

    static func access(of pasteboard: NSPasteboard) -> Access {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysDeny: return .denied
        case .ask: return .ask
        case .default, .alwaysAllow: return .allowed
        @unknown default: return .allowed
        }
    }

    /// Whether the first item looks like a web URL, checked without reading the
    /// contents and so without triggering the system paste alert.
    /// The 15.4 SDK ships only the Swift-refined (`__`) spelling of
    /// `detectPatterns`, so that is what is called. Completion runs on an
    /// arbitrary queue; before 15.4 it reports `false`.
    static func probablyContainsLink(_ pasteboard: NSPasteboard, completion: @escaping @Sendable (Bool) -> Void) {
        guard #available(macOS 15.4, *) else { completion(false); return }
        let patterns: Set<__NSPasteboardDetectionPattern> = [.__probableWebURL, .__link]
        pasteboard.__detectPatterns(forPatterns: patterns) { found, error in
            completion(error == nil && !(found ?? []).isEmpty)
        }
    }
}
