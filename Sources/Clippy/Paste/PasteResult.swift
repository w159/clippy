import Foundation

/// Why a clip could not be written to the pasteboard. Nothing is pasted (no
/// Cmd+V is sent) when a write fails (CAP-01).
enum PasteError: Error, Equatable {
    /// The image's stored bytes are missing or unreadable.
    case mediaMissing
    /// The file clip's original and stored copy are both gone.
    case fileUnavailable
    /// The pasteboard refused the write.
    case pasteboardWriteFailed
    /// Nothing pasteable (for example a combine of only image clips).
    case nothingToPaste
    /// The frontmost app changed away from the paste target mid-sequence.
    case targetChanged

    /// Short, banner-ready description.
    var message: String {
        switch self {
        case .mediaMissing: return "The image data for this clip is missing."
        case .fileUnavailable: return "The file for this clip is no longer available."
        case .pasteboardWriteFailed: return "Clippy could not write to the clipboard."
        case .nothingToPaste: return "There is nothing to paste."
        case .targetChanged: return "Paste stopped because the active app changed."
        }
    }
}

/// Outcome of a paste.
enum PasteResult: Equatable {
    /// Written to the pasteboard and the paste keystroke was sent.
    case pasted
    /// Written to the pasteboard, but the keystroke was not sent.
    case copiedOnly(CopyOnlyReason)
    /// Not written; nothing was pasted.
    case failed(PasteError)

    enum CopyOnlyReason: Equatable {
        /// Accessibility permission is missing.
        case accessibilityNotGranted
        /// The target app did not become active before the timeout.
        case targetNotActivated
    }
}
