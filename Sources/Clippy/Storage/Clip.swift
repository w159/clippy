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

    var isRich: Bool {
        contentRTF != nil || contentHTML != nil
    }

    /// Media filenames this clip owns on disk (empty for text clips).
    var mediaFilenames: [String] {
        [mediaFilename, thumbFilename].compactMap { $0 }
    }
}
