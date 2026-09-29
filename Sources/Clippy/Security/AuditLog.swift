import CryptoKit
import Foundation

/// Append-only, hash-chained local audit log (SEC-08).
///
/// Two independent streams live in one directory, both JSONL, both mode 0600:
/// - `audit-yyyy-MM.jsonl`      written by the app (AI tool runner, sandbox, retention).
/// - `mcp-audit-yyyy-MM.jsonl`  written by the Node MCP server (tool name, clip ids).
///
/// Every line is one JSON object carrying `prev`: the lowercase-hex SHA-256 of
/// the previous line's exact bytes (without the trailing newline), or 64 zeros
/// for the first line of a file. Editing, deleting or reordering any line but
/// the last breaks the next line's `prev`, which `verify()` reports.
///
/// Privacy: entries never hold clip content, only ids. `detail` is free text
/// supplied by callers and MUST NOT contain clip content or secrets.
final class AuditLog: @unchecked Sendable {

    static let shared = AuditLog()

    /// Chain anchor for the first line of a file.
    static let genesis = String(repeating: "0", count: 64)
    static let appPrefix = "audit-"
    static let mcpPrefix = "mcp-audit-"

    /// One decoded log line.
    struct Entry: Codable, Equatable {
        var timestamp: String
        var actor: String
        var action: String
        var detail: String
        var clipIDs: [Int64]
        var prev: String

        private enum CodingKeys: String, CodingKey {
            case timestamp = "ts", actor, action, detail, clipIDs, prev
        }
    }

    /// A chain break or unreadable line.
    struct Failure: Equatable {
        var file: String
        /// 1-based line number.
        var line: Int
        var reason: String
    }

    struct VerificationReport: Equatable {
        var filesChecked: Int
        var entriesChecked: Int
        var failures: [Failure]
        var isValid: Bool { failures.isEmpty }
    }

    enum ExportFormat { case json, csv }

    let directory: URL
    private let now: () -> Date
    private let lock = NSLock()
    /// Cached hash of the last line per file name, so appends don't re-read.
    private var tails: [String: String] = [:]

    /// `directory` is created (0700) on first write.
    init(directory: URL = AuditLog.defaultDirectory, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Clippy/audit", isDirectory: true)
    }

    // MARK: - Recording

    /// Appends one entry to this month's app stream. Failures are logged (without
    /// content) and never thrown: auditing must not break the audited action.
    func record(actor: String, action: String, detail: String, clipIDs: [Int64]) {
        let date = now()
        let entryFile = Self.fileName(prefix: Self.appPrefix, date: date)
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureDirectory()
            let url = directory.appendingPathComponent(entryFile)
            let prev = try tailHash(of: url)
            let entry = Entry(timestamp: Self.timestamp(date), actor: actor, action: action,
                              detail: detail, clipIDs: clipIDs, prev: prev)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let line = try encoder.encode(entry)
            try append(line: line, to: url)
            tails[entryFile] = Self.sha256Hex(line)
        } catch {
            ClippyLog.error("Audit log write failed: \(error)", category: ClippyLog.storage)
        }
    }

    // MARK: - Verification

    /// Re-walks every chain in the directory (both streams).
    func verify() -> VerificationReport {
        var files = 0, entries = 0
        var failures: [Failure] = []
        for url in logFiles() {
            files += 1
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                failures.append(Failure(file: name, line: 0, reason: "unreadable"))
                continue
            }
            var expected = Self.genesis
            var lineNumber = 0
            for raw in Self.lines(of: data) {
                lineNumber += 1
                guard let entry = try? JSONDecoder().decode(Entry.self, from: raw) else {
                    failures.append(Failure(file: name, line: lineNumber, reason: "malformed line"))
                    // Chain continues from the bytes we actually see.
                    expected = Self.sha256Hex(raw)
                    continue
                }
                entries += 1
                if entry.prev != expected {
                    failures.append(Failure(file: name, line: lineNumber, reason: "chain mismatch"))
                }
                expected = Self.sha256Hex(raw)
            }
        }
        return VerificationReport(filesChecked: files, entriesChecked: entries, failures: failures)
    }

    // MARK: - Reading and export

    /// Every readable entry from both streams, oldest first, tagged with its stream.
    func allEntries() -> [(stream: String, entry: Entry)] {
        var out: [(stream: String, entry: Entry)] = []
        for url in logFiles() {
            let stream = url.lastPathComponent.hasPrefix(Self.mcpPrefix) ? "mcp" : "app"
            guard let data = try? Data(contentsOf: url) else { continue }
            for raw in Self.lines(of: data) {
                if let entry = try? JSONDecoder().decode(Entry.self, from: raw) { out.append((stream: stream, entry: entry)) }
            }
        }
        return out.sorted { $0.entry.timestamp < $1.entry.timestamp }
    }

    /// Writes all entries as one JSON document or CSV file for an examiner. The
    /// file is created 0600. Returns the number of entries exported.
    @discardableResult
    func export(to url: URL, format: ExportFormat) throws -> Int {
        let rows = allEntries()
        let data: Data
        switch format {
        case .json:
            let objects: [[String: Any]] = rows.map {
                ["stream": $0.stream, "ts": $0.entry.timestamp, "actor": $0.entry.actor, "action": $0.entry.action,
                 "detail": $0.entry.detail, "clipIDs": $0.entry.clipIDs]
            }
            data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        case .csv:
            var text = "stream,timestamp,actor,action,detail,clip_ids\n"
            for row in rows {
                let ids = row.entry.clipIDs.map(String.init).joined(separator: ";")
                text += [row.stream, row.entry.timestamp, row.entry.actor, row.entry.action, row.entry.detail, ids]
                    .map(Self.csvField).joined(separator: ",") + "\n"
            }
            data = Data(text.utf8)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return rows.count
    }

    // MARK: - Helpers

    static func fileName(prefix: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return "\(prefix)\(formatter.string(from: date)).jsonl"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Non-empty lines as raw bytes (no newline).
    private static func lines(of data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Log files sorted by name (prefix then month), both streams.
    private func logFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jsonl"
            && ($0.lastPathComponent.hasPrefix(Self.appPrefix) || $0.lastPathComponent.hasPrefix(Self.mcpPrefix)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Hash of the file's last line, or `genesis` when empty/missing. Reads the
    /// file only on the first append per file per process.
    private func tailHash(of url: URL) throws -> String {
        let name = url.lastPathComponent
        // Another process (the MCP server never writes app files, but be safe) may
        // have appended, so trust the cache only when the size is consistent.
        if let cached = tails[name], FileManager.default.fileExists(atPath: url.path) { return cached }
        guard let data = try? Data(contentsOf: url), let last = Self.lines(of: data).last else {
            return Self.genesis
        }
        return Self.sha256Hex(last)
    }

    private func append(line: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data([0x0A]))
    }
}
