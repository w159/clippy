import AppKit
import Foundation
import GRDB
import TOMLKit

// The clippy.toml archive: a human-readable, structured export of every
// category (name, color, icon, position) together with the clips pinned into
// it. Designed to be hand-edited in bulk and re-imported.
//
// Schema (schema_version = 1):
//
//   schema_version = 1
//   exported_at    = "2026-06-11T04:00:00Z"   # ISO-8601, informational
//
//   [[category]]
//   name      = "Pinned"
//   color     = "#FF9500"     # hex RRGGBB
//   icon_kind = "symbol"      # "symbol" (SF Symbol) | "emoji" | "app" (bundle id)
//   icon      = "pin.fill"    # symbol name, emoji character, or app bundle id
//   position  = 0             # display order; lower sits higher in the list
//   starter   = true          # the built-in quick-pin category; at most one
//
//     [[category.clip]]
//     kind       = "text"            # "text" | "image"
//     title      = "Build"           # optional; omit to show the source app name
//     text       = "swift build"     # required for text clips
//     source_app = "Terminal"        # optional, informational
//     created_at = "2026-06-11T03:00:00Z"  # optional
//
//     [[category.clip]]
//     kind       = "image"
//     media      = "media/ab12.png"  # path RELATIVE to the archive package
//
//     [[category.clip]]
//     kind       = "file"
//     file_name  = "report.pdf"
//     file_path  = "/Users/me/report.pdf"   # original location, informational
//     media      = "media/cd34.pdf"         # bundled bytes, when they were stored
//
// On disk the archive is a package directory (`*.clippyarchive`) holding
// `clippy.toml` plus a `media/` folder with every referenced file, so images and
// files travel between Macs (DAT-07). All `media` paths are relative and are
// confined to the package on import (absolute paths and `..` are rejected). The
// legacy absolute `image_path` key is still read for old archives.
//
// Import is idempotent and runs in ONE database transaction: categories are
// matched by name (case-insensitive) and updated in place, identical clips are
// reused with newest-wins metadata, and a failure rolls everything back.

// MARK: - Codable model

struct ClippyArchiveDocument: Codable, Equatable {
    var schemaVersion: Int
    var exportedAt: String
    var category: [ArchivedCategory]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case category
    }
}

struct ArchivedCategory: Codable, Equatable {
    var name: String
    var color: String
    var iconKind: String
    var icon: String
    var position: Int
    var starter: Bool
    /// Optional: a category with no pinned clips omits the `[[category.clip]]`
    /// tables entirely, so the key is absent rather than an empty array.
    var clip: [ArchivedClip]?

    enum CodingKeys: String, CodingKey {
        case name, color, icon, position, starter, clip
        case iconKind = "icon_kind"
    }
}

struct ArchivedClip: Codable, Equatable {
    var kind: String
    var title: String?
    var text: String?
    /// Legacy absolute path written by pre-package archives. Read-only.
    var imagePath: String?
    /// Package-relative path of the bundled media (image or file bytes).
    var media: String?
    var fileName: String?
    var filePath: String?
    var sourceApp: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, text, media
        case imagePath = "image_path"
        case fileName = "file_name"
        case filePath = "file_path"
        case sourceApp = "source_app"
        case createdAt = "created_at"
    }
}

/// What an import did, for a confirmation message.
struct ImportSummary: Equatable {
    var categories = 0
    var clips = 0
    var skippedImages = 0
    /// File clips with neither bundled bytes nor an original path.
    var skippedFiles = 0
}

/// What `exportPackage` wrote.
struct ArchiveExportResult: Equatable {
    var categories = 0
    var clips = 0
    var mediaFiles = 0
    /// Referenced media the store no longer had on disk (those clips import as skipped).
    var missingMedia: [String] = []
}

enum ClippyArchiveError: Error, Equatable, LocalizedError {
    case missingManifest(String)
    case destinationInvalid

    var errorDescription: String? {
        switch self {
        case .missingManifest(let path): return "No clippy.toml found in the archive at \(path)."
        case .destinationInvalid: return "The archive destination is not a usable folder."
        }
    }
}

// MARK: - icon kind <-> TOML

extension CategoryIconKind {
    /// "app" reads better than "appLogo" in a hand-edited file.
    var tomlValue: String { self == .appLogo ? "app" : rawValue }

    static func fromTOML(_ value: String) -> CategoryIconKind {
        switch value.lowercased() {
        case "app", "applogo": return .appLogo
        case "emoji": return .emoji
        default: return .symbol
        }
    }
}

// MARK: - Encode / decode + DB bridge

enum ClippyArchive {
    private static let header = """
        # Clippy archive - categories and their pinned clips.
        # Edit names, colors, icons, order, or clip text and re-import.
        # Re-importing is idempotent: categories are matched by name and updated
        # in place; identical text clips are reused, not duplicated.

        """

    static let manifestName = "clippy.toml"
    static let mediaFolder = "media"
    static let packageExtension = "clippyarchive"

    private static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    // MARK: Export

    /// Build the TOML text for the whole archive from the database. Hand-written
    /// (rather than encoded) so the field order, alignment, and nesting stay in
    /// the logical, human-readable shape documented above. Parsing on import
    /// goes through a real TOML parser, so any valid hand edit round-trips.
    static func exportTOML(from database: ClipDatabase, now: Date = Date()) throws -> String {
        let iso = isoFormatter
        let groups = try database.clipsGroupedByCategory()

        var out = header
        out += pair("schema_version", "1", width: 15)
        out += pair("exported_at", quote(iso.string(from: now)), width: 15)

        for group in groups {
            let category = group.category
            out += "\n[[category]]\n"
            out += pair("name", quote(category.name), width: 10)
            out += pair("color", quote(category.colorHex), width: 10)
            out += pair("icon_kind", quote(category.iconKind.tomlValue), width: 10)
            out += pair("icon", quote(category.iconValue), width: 10)
            out += pair("position", String(category.sortOrder), width: 10)
            out += pair("starter", category.isStarter ? "true" : "false", width: 10)

            for clip in group.clips {
                out += "\n  [[category.clip]]\n"
                out += clipPair("kind", quote(clip.contentKind.rawValue))
                if let title = clip.userTitle {
                    out += clipPair("title", quote(title))
                }
                if clip.contentKind == .text {
                    out += clipPair("text", quote(clip.contentText))
                } else if clip.contentKind == .file {
                    out += clipPair("file_name", quote(clip.contentText))
                    if let path = clip.filePath { out += clipPair("file_path", quote(path)) }
                    if let media = clip.mediaFilename { out += clipPair("media", quote("\(mediaFolder)/\(media)")) }
                } else if let media = clip.mediaFilename {
                    out += clipPair("media", quote("\(mediaFolder)/\(media)"))
                }
                if let app = clip.sourceAppName {
                    out += clipPair("source_app", quote(app))
                }
                out += clipPair("created_at", quote(iso.string(from: clip.createdAt)))
            }
        }
        return out
    }

    /// Write the archive as a package directory at `destination`: `clippy.toml`
    /// plus `media/` with every referenced file. Built in a sibling temp folder
    /// and swapped in, so a failure never leaves a half-written package.
    @discardableResult
    static func exportPackage(from database: ClipDatabase, to destination: URL,
                              now: Date = Date()) throws -> ArchiveExportResult {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else { throw ClippyArchiveError.destinationInvalid }
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging.appendingPathComponent(mediaFolder), withIntermediateDirectories: true)
        do {
            var result = ArchiveExportResult()
            let groups = try database.clipsGroupedByCategory()
            var copied = Set<String>()
            for group in groups {
                result.categories += 1
                for clip in group.clips {
                    result.clips += 1
                    guard clip.contentKind != .text, let media = clip.mediaFilename,
                          copied.insert(media).inserted else { continue }
                    let source = database.media.url(for: media)
                    guard fileManager.fileExists(atPath: source.path) else { result.missingMedia.append(media); continue }
                    try fileManager.copyItem(at: source,
                                    to: staging.appendingPathComponent(mediaFolder).appendingPathComponent(media))
                    result.mediaFiles += 1
                }
            }
            let toml = try exportTOML(from: database, now: now)
            try toml.write(to: staging.appendingPathComponent(manifestName), atomically: true, encoding: .utf8)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            return result
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Hand-written TOML helpers

    /// `key  = value` with the key padded to `width` for column alignment.
    private static func pair(_ key: String, _ value: String, width: Int) -> String {
        let padding = String(repeating: " ", count: max(1, width - key.count))
        return "\(key)\(padding)= \(value)\n"
    }

    /// A clip field: two-space indented under its `[[category.clip]]`, keys
    /// padded to the widest clip key ("created_at"/"source_app"/"image_path").
    private static func clipPair(_ key: String, _ value: String) -> String {
        "  " + pair(key, value, width: 11)
    }

    /// TOML basic string literal with full escaping.
    ///
    /// Always emits a single-line basic string delimited by `"..."`.  All
    /// content that would be invalid or ambiguous in a TOML basic string is
    /// escaped using the standard TOML escape sequences, so the result is
    /// valid for any arbitrary Unicode text including multi-line content,
    /// triple-quote sequences, control characters, and NUL bytes.
    ///
    /// Escape order matters: backslash must be doubled before any other
    /// sequence is substituted, otherwise the newly-inserted backslashes
    /// would themselves be double-escaped.
    private static func quote(_ string: String) -> String {
        var body = string

        // 1. Backslash must come first.
        body = body.replacingOccurrences(of: "\\", with: "\\\\")

        // 2. Double-quote (the delimiter).
        body = body.replacingOccurrences(of: "\"", with: "\\\"")

        // 3. Named TOML escape sequences for common control characters.
        body = body.replacingOccurrences(of: "\u{08}", with: "\\b")
        body = body.replacingOccurrences(of: "\t",     with: "\\t")
        body = body.replacingOccurrences(of: "\n",     with: "\\n")
        body = body.replacingOccurrences(of: "\u{0C}", with: "\\f")
        body = body.replacingOccurrences(of: "\r",     with: "\\r")

        // 4. Remaining control characters (< U+0020, and U+007F) that have
        //    no named escape are encoded as \uXXXX (4 uppercase hex digits).
        var result = ""
        result.reserveCapacity(body.unicodeScalars.count)
        for scalar in body.unicodeScalars {
            let codePoint = scalar.value
            if codePoint < 0x20 || codePoint == 0x7F {
                result += String(format: "\\u%04X", codePoint)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        return "\"\(result)\""
    }

    // MARK: Import

    /// Import a package directory produced by `exportPackage`.
    @discardableResult
    static func importPackage(at packageURL: URL, into database: ClipDatabase) throws -> ImportSummary {
        let manifest = packageURL.appendingPathComponent(manifestName)
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            throw ClippyArchiveError.missingManifest(packageURL.path)
        }
        return try importTOML(text, into: database, baseURL: packageURL)
    }

    /// Resolve an archive-relative media path against `base`, refusing anything
    /// that could escape it (absolute paths, `..`, symlink escapes).
    static func resolveMedia(_ relative: String, in base: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        let root = base.resolvingSymlinksInPath().standardizedFileURL
        let candidate = parts.reduce(root) { $0.appendingPathComponent(String($1)) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    /// What Pass 1 (file IO, outside the transaction) prepared for one clip.
    private enum Staged {
        case text(String)
        case image(MediaStore.StoredImage)
        case file(name: String, path: String?, stored: MediaStore.StoredFile?)
        case skippedImage
        case skippedFile
        case empty
    }

    /// Parse TOML text and apply it to the database in ONE transaction. Media
    /// paths are resolved against `baseURL` (the package folder). With no
    /// `baseURL` (a bare clippy.toml) a `media/<name>` reference falls back to
    /// the local media store, which restores same-Mac exports.
    @discardableResult
    static func importTOML(_ text: String, into database: ClipDatabase,
                           baseURL: URL? = nil) throws -> ImportSummary {
        let document = try TOMLDecoder().decode(ClippyArchiveDocument.self, from: text)
        let iso = isoFormatter
        let fileManager = FileManager.default
        let before = Set((try? fileManager.contentsOfDirectory(atPath: database.media.directory.path)) ?? [])

        func mediaURL(for clip: ArchivedClip) -> URL? {
            if let rel = clip.media {
                if let baseURL { return resolveMedia(rel, in: baseURL) }
                let name = (rel as NSString).lastPathComponent
                return name.isEmpty || name == ".." ? nil : database.media.url(for: name)
            }
            return clip.imagePath.map { URL(fileURLWithPath: $0) }
        }

        // Pass 1: read and store media outside the transaction (file IO).
        var staged: [[Staged]] = []
        do {
            for category in document.category {
                var row: [Staged] = []
                for clip in category.clip ?? [] {
                    row.append(stage(clip, mediaURL: mediaURL(for: clip), database: database))
                }
                staged.append(row)
            }

            // Pass 2: everything else, atomically.
            var summary = ImportSummary()
            var evicted: [String] = []
            try database.dbQueue.write { connection in
                for (index, category) in document.category.enumerated() {
                    let categoryID = try ClipDatabase.upsertImportedCategory(
                        connection, name: category.name, colorHex: category.color,
                        iconKind: CategoryIconKind.fromTOML(category.iconKind),
                        iconValue: category.icon, position: category.position, starter: category.starter)
                    summary.categories += 1
                    for (position, item) in staged[index].enumerated() {
                        let clip = (category.clip ?? [])[position]
                        let created = clip.createdAt.flatMap { iso.date(from: $0) } ?? Date()
                        let clipID: Int64
                        switch item {
                        case .text(let value):
                            clipID = try ClipDatabase.upsertImportedTextClip(
                                connection, text: value, title: clip.title, sourceApp: clip.sourceApp, createdAt: created)
                        case .image(let stored):
                            clipID = try ClipDatabase.upsertImportedImageClip(
                                connection, stored: stored, title: clip.title, sourceApp: clip.sourceApp, createdAt: created)
                        case .file(let name, let path, let stored):
                            clipID = try ClipDatabase.upsertImportedFileClip(
                                connection, displayName: name, filePath: path, stored: stored,
                                title: clip.title, sourceApp: clip.sourceApp, createdAt: created)
                        case .skippedImage: summary.skippedImages += 1; continue
                        case .skippedFile: summary.skippedFiles += 1; continue
                        case .empty: continue
                        }
                        try ClipDatabase.addImportedMembership(
                            connection, clipID: clipID, categoryID: categoryID, position: position)
                        summary.clips += 1
                    }
                }
                // Categorized clips are exempt; this trims only uncategorized overflow.
                evicted = try ClipDatabase.enforceLimits(connection, cap: AppSettings.storedMaxHistoryItems)
            }
            database.media.delete(filenames: evicted)
            return summary
        } catch {
            // Rolled back: drop media this import newly wrote and nothing references.
            let referenced = (try? database.referencedMediaFilenames()) ?? []
            let now = Set((try? fileManager.contentsOfDirectory(atPath: database.media.directory.path)) ?? [])
            database.media.delete(filenames: now.subtracting(before).subtracting(referenced).map { $0 })
            throw error
        }
    }

    /// Pass 1 for one clip. Never throws: an unreadable payload becomes a skip.
    private static func stage(_ clip: ArchivedClip, mediaURL: URL?, database: ClipDatabase) -> Staged {
        switch clip.kind {
        case "image":
            guard let url = mediaURL, let raw = FileManager.default.contents(atPath: url.path),
                  let image = NSImage(data: raw), let png = MediaStore.pngData(from: image),
                  let stored = try? database.media.store(pngData: png) else { return .skippedImage }
            return .image(stored)
        case "file":
            let path = clip.filePath
            var stored: MediaStore.StoredFile?
            if let url = mediaURL, FileManager.default.fileExists(atPath: url.path),
               var file = try? database.media.storeFile(at: url) {
                let hash = (file.mediaFilename as NSString).deletingPathExtension
                if let thumb = database.media.imageThumbnail(forFileAt: url, hash: hash) {
                    file.thumbFilename = thumb.thumbFilename
                    file.pixelWidth = thumb.pixelWidth
                    file.pixelHeight = thumb.pixelHeight
                }
                stored = file
            }
            guard stored != nil || path != nil else { return .skippedFile }
            let name = clip.fileName ?? path.map { ($0 as NSString).lastPathComponent } ?? "File"
            return .file(name: name, path: path, stored: stored)
        default:
            let value = clip.text ?? ""
            return value.isEmpty ? .empty : .text(value)
        }
    }
}
