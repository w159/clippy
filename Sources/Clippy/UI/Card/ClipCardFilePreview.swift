import SwiftUI

/// File and color-swatch previews for `ClipCardView`, plus the file-clip actions
/// (paste, reveal, move, extract) used when the parent supplies no override.
extension ClipCardView {
    // MARK: - File-clip actions

    /// Resolves the best URL for the file clip: live original first, stored copy second.
    var resolvedFileURL: URL? {
        if let path = clip.filePath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let mediaFilename = clip.mediaFilename else { return nil }
        let stored = ClipDatabase.shared.media.url(for: mediaFilename)
        return FileManager.default.fileExists(atPath: stored.path) ? stored : nil
    }

    func filePasteAction() {
        if let override = onPasteFile { override(); return }
        // Paste directly: write the URL to the pasteboard (no keystroke; the
        // panel dismiss gives focus back, then the user can Cmd+V manually, or
        // the parent wires a real PasteService call via onPasteFile).
        guard let url = resolvedFileURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        (url as NSURL).write(to: pasteboard)
    }

    func fileRevealAction() {
        if let override = onRevealInFinder { override(); return }
        guard let url = resolvedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func fileMoveAction() {
        if let override = onMoveFile { override(); return }
        // Move is only meaningful with Accessibility permission; the parent
        // should supply onMoveFile wired to PasteService.pasteFile(_:move:true).
        filePasteAction()
    }

    func fileExtractAction() {
        if let override = onExtractZip { override(); return }
        guard let archiveURL = resolvedFileURL else { return }
        let name = archiveURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let destDir = downloads.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", archiveURL.path, destDir.path]
        proc.terminationHandler = { process in
            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([destDir])
                }
                // Failure is silently swallowed; no partial state to clean up.
            }
        }
        try? proc.run()
    }

    var filePreview: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: clip.contentText.hasSuffix(".zip") ? "doc.zipper" : "doc")
                .font(.system(size: placeholderIconSize, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(kind.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.contentText)
                    .font(PanelTypography.body(settings))
                    .lineLimit(2)
                    .foregroundStyle(tokens.textPrimary)
                if let byteSize = clip.byteSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                        .monospacedDigit()
                }
                // Reference-only badge: stored bytes not available.
                if clip.mediaFilename == nil {
                    Text("Path reference only")
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
