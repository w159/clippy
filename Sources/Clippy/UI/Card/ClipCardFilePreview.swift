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
        guard let url = resolvedFileURL else {
            FileActionAlert.present(title: "File not found", detail: FileActionAlert.missingFileDetail(clip.filePath))
            return
        }
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
        guard let archiveURL = resolvedFileURL else {
            FileActionAlert.present(title: "Can't extract", detail: FileActionAlert.missingFileDetail(clip.filePath))
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        // A fresh folder every time ("report", "report 2", ...): extraction must never merge into
        // or overwrite something that is already in Downloads.
        let destDir = ZipExtractNaming.uniqueDirectory(
            baseName: archiveURL.deletingPathExtension().lastPathComponent, in: downloads
        ) { FileManager.default.fileExists(atPath: $0.path) }
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: false)
        } catch {
            FileActionAlert.present(title: "Can't extract", detail: "Couldn't create the folder \(destDir.lastPathComponent) in Downloads: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", archiveURL.path, destDir.path]
        // stderr goes to a temp file, not a Pipe: a Pipe read only at termination would
        // block ditto forever once it wrote more than the 64 KB pipe buffer.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-ditto-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            try? FileManager.default.removeItem(at: destDir)
            FileActionAlert.present(title: "Extraction failed", detail: ZipExtractNaming.failureDetail(reason: "Couldn't create a temporary log file."))
            return
        }
        proc.standardError = logHandle
        proc.terminationHandler = { process in
            let status = process.terminationStatus
            try? (process.standardError as? FileHandle)?.close()
            let stderr = (try? Data(contentsOf: logURL)) ?? Data()
            try? FileManager.default.removeItem(at: logURL)
            let reason = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                if status == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([destDir])
                } else {
                    try? FileManager.default.removeItem(at: destDir)
                    FileActionAlert.present(title: "Extraction failed", detail: ZipExtractNaming.failureDetail(reason: reason))
                }
            }
        }
        do {
            try proc.run()
        } catch {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: destDir)
            FileActionAlert.present(title: "Extraction failed", detail: ZipExtractNaming.failureDetail(reason: error.localizedDescription))
        }
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
                        .foregroundStyle(cardSecondaryText)
                        .monospacedDigit()
                }
                // Reference-only badge: stored bytes not available.
                if clip.mediaFilename == nil {
                    Text("Path reference only")
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(cardSecondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
