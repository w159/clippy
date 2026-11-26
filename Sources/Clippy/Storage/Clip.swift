import CryptoKit
import Foundation
import GRDB

enum ClipContentKind: String, Codable {
    case text
    case image
    case file
}

struct Clip: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var contentText: String
    var contentRTF: Data?
    var contentHTML: Data?
    var typeIdentifier: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var contentKind: ClipContentKind = .text
    var mediaFilename: String?
    var thumbFilename: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteSize: Int?
    /// User-supplied display name. When nil the source app name is shown instead.
    var userTitle: String? = nil
    /// Original file system path. Populated for file clips only. Nil for text/image clips.
    var filePath: String? = nil
    /// Text recognised in an image clip by the background OCR indexer (searchable).
    /// nil = not scanned yet, "" = scanned, no text found.
    var ocrText: String? = nil
    /// True when this copy came from a list fetch (`Clip.light`) that skipped the
    /// RTF and HTML blobs of a clip that has them. Never persisted or encoded;
    /// `ClipDatabase.withRichContent` fills the blobs in before they are used.
    /// A light clip must never be written back whole: every write of an existing
    /// clip goes through targeted `UPDATE` statements by id.
    var richContentOmitted: Bool = false

    /// Persisted columns only: `richContentOmitted` stays out of every encode path.
    private enum CodingKeys: String, CodingKey {
        case id, contentText, contentRTF, contentHTML, typeIdentifier, sourceAppBundleID, sourceAppName
        case createdAt, contentKind, mediaFilename, thumbFilename, pixelWidth, pixelHeight, byteSize
        case userTitle, filePath, ocrText
    }

    static let databaseTableName = "clips"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The title shown in the card header: user's custom name when set,
    /// otherwise the source app name, otherwise a generic fallback.
    var displayTitle: String {
        userTitle ?? sourceAppName ?? "Unknown app"
    }

    /// Single-line-ish preview for list rows.
    ///
    /// Takes the prefix before trimming (CAP-07): only leading whitespace is
    /// skipped lazily and only 300 characters are ever copied, so a 100 MB clip
    /// never has its full text duplicated just to draw a card.
    var previewText: String {
        let head = String(contentText.drop(while: \.isWhitespace).prefix(300))
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stable key for sidecar data (flavors, sensitive flag): a SHA-256 of the
    /// content, never the content itself. Text clips hash the text; image and
    /// file clips reuse their content-hash media filename, so the key survives
    /// re-copies and matches what capture computed before the row existed.
    var contentKey: String {
        Self.contentKey(kind: contentKind, text: contentText, mediaFilename: mediaFilename, filePath: filePath)
    }

    /// Key computed from the parts capture has before a `Clip` exists.
    static func contentKey(kind: ClipContentKind, text: String, mediaFilename: String?, filePath: String?) -> String {
        switch kind {
        case .text:
            return "t-" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        case .image, .file:
            if let mediaFilename { return "m-" + mediaFilename }
            return "p-" + SHA256.hash(data: Data((filePath ?? text).utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Whether the clip carries formatting. True for a light copy whose blobs
    /// were skipped, so badges and editor mode do not depend on which copy it is.
    var hasRichContent: Bool {
        richContentOmitted || contentRTF != nil || contentHTML != nil
    }

    /// Media filenames this clip owns on disk (empty for text clips).
    var mediaFilenames: [String] {
        [mediaFilename, thumbFilename].compactMap { $0 }
    }
}

// MARK: - Light rows

extension Clip {
    /// Light columns in select order. The raw value is the column index
    /// `light(_:)` reads, so the SELECT list and the decoder share one source.
    private enum LightColumn: Int, CaseIterable {
        case id, contentText, typeIdentifier, sourceAppBundleID, sourceAppName, createdAt
        case contentKind, mediaFilename, thumbFilename, pixelWidth, pixelHeight, byteSize
        case userTitle, filePath, ocrText, hasRichContent
    }

    /// Number of columns `lightColumns` selects; extra columns start at this index.
    static let lightColumnCount = LightColumn.allCases.count

    /// Every `clips` column except the RTF and HTML blobs, plus `hasRichContent`
    /// computed in SQL. Lists need none of the blobs; paste, copy, edit, export
    /// and archive read them through `ClipDatabase.withRichContent`.
    /// `alias` is the table alias when the query joins other tables.
    static func lightColumns(alias: String? = nil) -> String {
        let prefix = alias.map { $0 + "." } ?? ""
        let columns = LightColumn.allCases.dropLast().map { column in prefix + String(describing: column) }.joined(separator: ", ")
        // typeof() reads only the record header; IS NOT NULL would load the blobs.
        return columns + ", (typeof(\(prefix)contentRTF) = 'blob' OR typeof(\(prefix)contentHTML) = 'blob') AS \(LightColumn.hasRichContent)"
    }

    /// Decodes a row selected with `lightColumns` (extra columns may follow) by
    /// index, skipping the Codable row decoder: blobs nil, and
    /// `richContentOmitted` set only when the stored clip has formatting.
    static func light(_ row: Row) throws -> Clip {
        let createdAtValue: DatabaseValue = row[LightColumn.createdAt.rawValue]
        let kindValue: DatabaseValue = row[LightColumn.contentKind.rawValue]
        guard let createdAt = Date.fromDatabaseValue(createdAtValue) else {
            throw DatabaseError(message: "Clip.light: undecodable createdAt")
        }
        guard let kindRaw = String.fromDatabaseValue(kindValue), let kind = ClipContentKind(rawValue: kindRaw) else {
            throw DatabaseError(message: "Clip.light: undecodable contentKind")
        }
        var clip = Clip(
            id: row[LightColumn.id.rawValue],
            contentText: row[LightColumn.contentText.rawValue],
            contentRTF: nil,
            contentHTML: nil,
            typeIdentifier: row[LightColumn.typeIdentifier.rawValue],
            sourceAppBundleID: row[LightColumn.sourceAppBundleID.rawValue],
            sourceAppName: row[LightColumn.sourceAppName.rawValue],
            createdAt: createdAt)
        clip.contentKind = kind
        clip.mediaFilename = row[LightColumn.mediaFilename.rawValue]
        clip.thumbFilename = row[LightColumn.thumbFilename.rawValue]
        clip.pixelWidth = row[LightColumn.pixelWidth.rawValue]
        clip.pixelHeight = row[LightColumn.pixelHeight.rawValue]
        clip.byteSize = row[LightColumn.byteSize.rawValue]
        clip.userTitle = row[LightColumn.userTitle.rawValue]
        clip.filePath = row[LightColumn.filePath.rawValue]
        clip.ocrText = row[LightColumn.ocrText.rawValue]
        clip.richContentOmitted = row[LightColumn.hasRichContent.rawValue]
        return clip
    }

    /// Light rows for `ids`, in no particular order.
    static func fetchLight(_ db: Database, ids: [Int64]) throws -> [Clip] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let cursor = try Row.fetchCursor(
            db,
            sql: "SELECT \(lightColumns()) FROM clips WHERE id IN (\(marks))",
            arguments: StatementArguments(ids))
        var clips: [Clip] = []
        clips.reserveCapacity(ids.count)
        while let row = try cursor.next() { clips.append(try light(row)) }
        return clips
    }
}
