import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for a clip card (KEY-11 drag-out). One `.draggable` per card, so
/// this single item carries both the in-app token and the external content.
///
/// - In-app drops (`.dropDestination(for: String.self)` on category rows and
///   reorder targets) read the String representation, which is the `token`
///   ("clip:<id>" / "reorder:clip:<id>") unless `exportsText` is set.
/// - Image clips also offer their PNG and file clips their file URL, so Finder,
///   Mail, Preview and friends receive real content.
/// - Text clips export their text only when `exportsText` is set (the user held
///   Option at drag start), because the same String slot serves the in-app token.
/// - Sensitive clips never export content: only the in-app token leaves the card.
struct ClipDragItem: Transferable {
    let token: String
    let text: String?
    let imageURL: URL?
    let fileURL: URL?
    let exportsText: Bool

    /// Builds the item for `clip`. `optionHeld` selects real-text export.
    static func make(
        clip: Clip, token: String, media: MediaStore,
        isSensitive: Bool, optionHeld: Bool
    ) -> ClipDragItem {
        var text: String?
        var image: URL?
        var file: URL?
        if !isSensitive {
            switch clip.contentKind {
            case .text:
                text = clip.contentText
            case .image:
                image = clip.mediaFilename.map(media.url(for:)).flatMap(existing)
            case .file:
                if let path = clip.filePath, FileManager.default.fileExists(atPath: path) {
                    file = URL(fileURLWithPath: path)
                } else {
                    file = clip.mediaFilename.map(media.url(for:)).flatMap(existing)
                }
            }
        }
        return ClipDragItem(token: token, text: text, imageURL: image, fileURL: file,
                            exportsText: optionHeld && text != nil)
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            guard let url = item.imageURL else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.imageURL != nil }
        FileRepresentation(exportedContentType: .data) { item in
            guard let url = item.fileURL else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.fileURL != nil }
        ProxyRepresentation(exporting: { (item: ClipDragItem) in
            item.exportsText ? (item.text ?? item.token) : item.token
        })
    }
}
