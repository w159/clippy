import AppKit
import SwiftUI

/// ClippyArchive package export and import with a result summary.
struct DataArchiveSection: View {
    @Binding var notice: PaneNotice?
    @State private var busy = false
    @State private var summary: String?

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("Import and export", footer: "An archive is a folder with a readable manifest and your media. Importing adds clips; it does not replace history.") {
            SettingsRow(title: "Export archive", detail: Text(summary ?? "Saves categories and clips as a .\(ClippyArchive.packageExtension) package.")) {
                Button("Export\u{2026}") { exportArchive() }.disabled(busy)
            }
            Divider()
            SettingsRow(title: "Import archive") {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Button("Import\u{2026}") { importArchive() }.disabled(busy)
                }
            }
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clippy.\(ClippyArchive.packageExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try ClippyArchive.exportPackage(from: ClipDatabase.shared, to: url) } }.value
            busy = false
            switch result {
            case .success(let done):
                summary = "Exported \(done.clips) clips in \(done.categories) categories (\(done.mediaFiles) media files)."
                notice = .success(summary ?? "Exported.")
            case .failure: notice = .failure("Export failed.")
            }
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a Clippy archive package"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try ClippyArchive.importPackage(at: url, into: ClipDatabase.shared) } }.value
            busy = false
            switch result {
            case .success(let done):
                let skipped = done.skippedImages + done.skippedFiles
                summary = "Imported \(done.clips) clips in \(done.categories) categories" + (skipped > 0 ? "; \(skipped) skipped." : ".")
                notice = .success(summary ?? "Imported.")
            case .failure(let error): notice = .failure("Import failed: \(error.localizedDescription)")
            }
        }
    }
}
