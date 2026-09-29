import ClippyCLICore
import CryptoKit
import Foundation
import GRDB

/// One clip row as the CLI needs it. Content of sensitive clips is never loaded into output.
struct CLIClip {
    var id: Int64
    var text: String
    var kind: String
    var createdAt: Date
    var sourceApp: String?
    var title: String?
    var mediaFilename: String?
    var filePath: String?
    var byteSize: Int?

    /// Mirrors Swift `Clip.contentKey` / MCP `contentKey`.
    var contentKey: String {
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        if kind == "image" || kind == "file" {
            if let mediaFilename { return "m-" + mediaFilename }
            return "p-" + digest(filePath ?? text)
        }
        return "t-" + digest(text)
    }
}

/// Read-only access to the Clippy database with sensitive clips filtered out.
struct ClipReader {
    private let queue: DatabaseQueue
    let flags: SensitiveFlags

    /// Default location of the app database.
    static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
    }

    /// Opens `databasePath` read-only. The sidecar lives beside the database file.
    init(databasePath: String?) throws {
        let path = databasePath ?? Self.defaultSupportDirectory.appendingPathComponent("clippy.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { throw CLIError.runtime("database not found: \(path)") }
        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(path: path, configuration: config)
        flags = SensitiveFlags.load(supportDirectory: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    private static let columns = "id, contentText, contentKind, createdAt, sourceAppName, userTitle, mediaFilename, filePath, byteSize"

    private static func row(_ row: Row) -> CLIClip {
        CLIClip(id: row["id"], text: row["contentText"], kind: row["contentKind"] ?? "text", createdAt: row["createdAt"],
                sourceApp: row["sourceAppName"], title: row["userTitle"], mediaFilename: row["mediaFilename"],
                filePath: row["filePath"], byteSize: row["byteSize"])
    }

    /// Newest-first listing; sensitive clips are skipped (paged until `limit` visible rows).
    func list(limit: Int, kind: String?) throws -> [CLIClip] {
        var results: [CLIClip] = []
        var offset = 0
        while results.count < limit {
            let page: [CLIClip] = try queue.read { database in
                let filter = kind == nil ? "" : "WHERE contentKind = ?"
                var args: StatementArguments = kind.map { [$0] } ?? []
                args += [100, offset]
                return try Row.fetchAll(database, sql: """
                    SELECT \(Self.columns) FROM clips \(filter) ORDER BY createdAt DESC, id DESC LIMIT ? OFFSET ?
                    """, arguments: args).map(Self.row)
            }
            if page.isEmpty { break }
            offset += page.count
            results += page.filter { !flags.isSensitive(contentKey: $0.contentKey) }
        }
        return Array(results.prefix(limit))
    }

    /// FTS5 search over clip text and titles; words are ANDed, quoted phrases kept.
    func search(_ query: String, limit: Int) throws -> [CLIClip] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        var results: [CLIClip] = []
        var offset = 0
        while results.count < limit {
            let page: [CLIClip] = try queue.read { database in
                try Row.fetchAll(database, sql: """
                    SELECT \(Self.columns.split(separator: ",").map { "clips." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
                    FROM clips JOIN clips_fts ON clips_fts.rowid = clips.id
                    WHERE clips_fts MATCH ? ORDER BY rank LIMIT 100 OFFSET ?
                    """, arguments: [match, offset]).map(Self.row)
            }
            if page.isEmpty { break }
            offset += page.count
            results += page.filter { !flags.isSensitive(contentKey: $0.contentKey) }
        }
        return Array(results.prefix(limit))
    }

    /// Fetches one clip, or nil when missing. Caller decides how to treat sensitivity.
    func clip(id: Int64) throws -> CLIClip? {
        try queue.read { database in
            try Row.fetchOne(database, sql: "SELECT \(Self.columns) FROM clips WHERE id = ?", arguments: [id]).map(Self.row)
        }
    }

    /// Counts by kind plus how many are withheld as sensitive.
    func stats() throws -> (total: Int, byKind: [String: Int], sensitive: Int) {
        try queue.read { database in
            var total = 0
            var sensitive = 0
            var byKind: [String: Int] = [:]
            let cursor = try Row.fetchCursor(database, sql: "SELECT \(Self.columns) FROM clips")
            while let row = try cursor.next() {
                let clip = Self.row(row)
                total += 1
                byKind[clip.kind, default: 0] += 1
                if flags.isSensitive(contentKey: clip.contentKey) { sensitive += 1 }
            }
            return (total, byKind, sensitive)
        }
    }

    /// Quotes every term so FTS operators in user input cannot change the query.
    static func ftsQuery(_ raw: String) -> String {
        var terms: [String] = []
        var current = ""
        var inQuote = false
        for char in raw {
            if char == "\"" {
                if inQuote, !current.isEmpty { terms.append(current) }
                current = ""
                inQuote.toggle()
            } else if char.isWhitespace && !inQuote {
                if !current.isEmpty { terms.append(current) }
                current = ""
            } else { current.append(char) }
        }
        if !current.isEmpty { terms.append(current) }
        return terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ")
    }
}
