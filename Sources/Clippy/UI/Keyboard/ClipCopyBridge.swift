import AppKit

/// Cmd+C "copy without paste" (KEY-11). Writes the clip to the general
/// pasteboard without sending Cmd+V.
///
/// `wrapOwnWrite` lets the app route the write through
/// `ClipboardMonitor.performOwnWrite` so the copy is not re-captured as a new
/// clip; when unset the monitor sees an ordinary copy and dedupes it.
enum ClipCopyBridge {
    /// Set once at launch to `{ body in monitor.performOwnWrite(body) }`.
    nonisolated(unsafe) static var wrapOwnWrite: ((() -> Void) -> Void)?

    /// Copies `clips` (text joined by newline; the first image or file wins when
    /// mixed). Returns false when nothing could be written.
    @discardableResult
    static func copy(_ clips: [Clip], media: MediaStore, pasteboard: NSPasteboard = .general) -> Bool {
        guard let first = clips.first else { return false }
        var wrote = false
        let write = {
            if clips.count > 1 || first.contentKind == .text {
                let texts = clips.filter { $0.contentKind == .text }.map(\.contentText)
                guard !texts.isEmpty else { return }
                pasteboard.clearContents()
                let item = NSPasteboardItem()
                item.setString(texts.joined(separator: "\n"), forType: .string)
                if clips.count == 1 {
                    if let rtf = first.contentRTF { item.setData(rtf, forType: .rtf) }
                    if let html = first.contentHTML { item.setData(html, forType: .html) }
                }
                wrote = pasteboard.writeObjects([item])
            } else if first.contentKind == .image {
                guard let name = first.mediaFilename,
                      let data = try? Data(contentsOf: media.url(for: name)) else { return }
                pasteboard.clearContents()
                wrote = pasteboard.setData(data, forType: .png)
            } else if first.contentKind == .file {
                let url = first.filePath.map { URL(fileURLWithPath: $0) }.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                } ?? first.mediaFilename.map(media.url(for:))
                guard let url else { return }
                pasteboard.clearContents()
                wrote = pasteboard.writeObjects([url as NSURL])
            }
        }
        if let wrap = wrapOwnWrite { wrap(write) } else { write() }
        return wrote
    }
}
