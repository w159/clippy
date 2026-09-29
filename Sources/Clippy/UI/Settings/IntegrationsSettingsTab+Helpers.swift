import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension IntegrationsSettingsTab {
    /// True when the iCloud service has reported a sync write failure. The
    /// service surfaces failures by setting `status` to a "Sync failed:" string,
    /// so match that prefix rather than adding a property to that service.
    var syncStatusFailed: Bool {
        cloud.isAvailable && cloud.status.hasPrefix("Sync failed")
    }

    /// Shared NSSavePanel scaffold. Returns the result string to display, or nil
    /// when the user cancelled (so the caller leaves the prior message intact).
    func runSavePanel(name: String, types: [UTType],
                              _ body: (URL) throws -> String) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try body(url) }
        catch { return "Export failed: \(error.localizedDescription)" }
    }

    /// Shared NSOpenPanel scaffold. Same cancel semantics as runSavePanel.
    func runOpenPanel(types: [UTType],
                              _ body: (URL) throws -> String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try body(url) }
        catch { return "Import failed: \(error.localizedDescription)" }
    }

    func exportTOML() {
        let result = runSavePanel(name: "clippy.toml",
                                  types: [UTType(filenameExtension: "toml") ?? .plainText]) { url in
            let toml = try ClippyArchive.exportTOML(from: ClipDatabase.shared)
            try toml.write(to: url, atomically: true, encoding: .utf8)
            return "Exported categories and pinned clips to \(url.lastPathComponent)."
        }
        if let result { archiveResult = result }
    }

    func importTOML() {
        let result = runOpenPanel(types: [UTType(filenameExtension: "toml") ?? .plainText, .plainText, .text]) { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let summary = try ClippyArchive.importTOML(text, into: ClipDatabase.shared)
            var message = "Imported \(summary.categories) categories and \(summary.clips) clips."
            if summary.skippedImages > 0 {
                message += " Skipped \(summary.skippedImages) image(s) whose files were missing."
            }
            return message
        }
        if let result { archiveResult = result }
    }

    func exportJSON() {
        struct ExportClip: Encodable {
            let text: String
            let kind: String
            let mediaFile: String?
            let sourceApp: String?
            let sourceBundleID: String?
            let createdAt: Date
            let categories: [String]
        }
        struct ExportDocument: Encodable {
            let note: String
            let clips: [ExportClip]
        }

        let result = runSavePanel(name: "clippy-export.json", types: [.json]) { url in
            let database = ClipDatabase.shared
            let categories = try database.categories()
            let membership = try database.membershipMap()
            let nameByID = Dictionary(
                uniqueKeysWithValues: categories.compactMap { category in
                    category.id.map { ($0, category.name) }
                }
            )
            let clips = try database.allClips().map { clip in
                ExportClip(
                    text: clip.contentText,
                    kind: clip.contentKind.rawValue,
                    mediaFile: clip.mediaFilename.map { database.media.url(for: $0).path },
                    sourceApp: clip.sourceAppName,
                    sourceBundleID: clip.sourceAppBundleID,
                    createdAt: clip.createdAt,
                    categories: (clip.id.flatMap { membership[$0] } ?? [])
                        .compactMap { nameByID[$0] }
                        .sorted()
                )
            }
            let document = ExportDocument(
                note: "Image clips reference PNG files under the Clippy media folder; copy them separately if you need a portable backup.",
                clips: clips
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url)
            return "Exported \(clips.count) clips to \(url.lastPathComponent)."
        }
        if let result { exportResult = result }
    }
}
