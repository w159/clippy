import Foundation
import GRDB

/// Criteria of a rule-based collection. All present criteria must match (AND).
struct SmartCollectionRule: Codable, Equatable {
    /// Any of these kinds (OR).
    var kinds: [ClipKindToken] = []
    /// Case-insensitive substring of the source app name or bundle id.
    var sourceApp: String?
    /// Regular expression (case-insensitive) matched against the clip text or OCR text.
    var textPattern: String?
    /// Created more than N days ago.
    var olderThanDays: Int?
    /// Created within the last N days.
    var newerThanDays: Int?
    /// true = only sensitive clips, false = only non-sensitive.
    var sensitive: Bool?

    var isEmpty: Bool {
        kinds.isEmpty && sourceApp == nil && textPattern == nil && olderThanDays == nil
            && newerThanDays == nil && sensitive == nil
    }
}

struct SmartCollection: Identifiable, Equatable {
    var id: Int64?
    var name: String
    var rule: SmartCollectionRule
    var sortOrder: Int
}

enum SmartCollectionError: Error, Equatable {
    case emptyName, emptyRule, invalidPattern, invalidDays, notFound
}

extension ClipDatabase {
    /// Longest text scanned per clip by a rule regex, bounding worst-case cost.
    static let smartRuleScanLimit = 20_000

    static func validate(name: String, rule: SmartCollectionRule) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SmartCollectionError.emptyName }
        guard !rule.isEmpty else { throw SmartCollectionError.emptyRule }
        if let pattern = rule.textPattern {
            guard pattern.count <= 500, (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw SmartCollectionError.invalidPattern
            }
        }
        if let days = rule.olderThanDays, days < 0 { throw SmartCollectionError.invalidDays }
        if let days = rule.newerThanDays, days < 0 { throw SmartCollectionError.invalidDays }
        return trimmed
    }

    func smartCollections() throws -> [SmartCollection] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM smart_collections ORDER BY sortOrder, id").compactMap(Self.smartCollection)
        }
    }

    @discardableResult
    func createSmartCollection(name: String, rule: SmartCollectionRule) throws -> SmartCollection {
        let clean = try Self.validate(name: name, rule: rule)
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        return try dbQueue.write { db in
            let order = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) + 1 FROM smart_collections")) ?? 0
            try db.execute(sql: "INSERT INTO smart_collections (name, rule, sortOrder) VALUES (?, ?, ?)",
                           arguments: [clean, json, order])
            return SmartCollection(id: db.lastInsertedRowID, name: clean, rule: rule, sortOrder: order)
        }
    }

    func updateSmartCollection(id: Int64, name: String, rule: SmartCollectionRule) throws {
        let clean = try Self.validate(name: name, rule: rule)
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE smart_collections SET name = ?, rule = ? WHERE id = ?",
                           arguments: [clean, json, id])
            if db.changesCount == 0 { throw SmartCollectionError.notFound }
        }
    }

    func deleteSmartCollection(id: Int64) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM smart_collections WHERE id = ?", arguments: [id]) }
    }

    /// Gap-free renumbering in the given order; ids not listed keep their relative order after.
    func reorderSmartCollections(ids: [Int64]) throws {
        try dbQueue.write { db in
            let rest = try Int64.fetchAll(db, sql: "SELECT id FROM smart_collections ORDER BY sortOrder, id")
                .filter { !ids.contains($0) }
            for (index, id) in (ids + rest).enumerated() {
                try db.execute(sql: "UPDATE smart_collections SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }

    /// Clips matching a stored collection, newest first.
    func clips(inSmartCollection id: Int64, limit: Int = 300, now: Date = Date(),
               sensitiveStore: SensitiveFlagStore? = nil) throws -> [Clip] {
        guard let collection = try smartCollections().first(where: { $0.id == id }) else {
            throw SmartCollectionError.notFound
        }
        return try clips(matching: collection.rule, limit: limit, now: now, sensitiveStore: sensitiveStore)
    }

    /// Evaluates `rule`: SQL narrows by kind/app/age, Swift finishes derived kinds,
    /// the regex and the sensitive flag, paging until `limit` or exhaustion.
    func clips(matching rule: SmartCollectionRule, limit: Int, now: Date = Date(),
               sensitiveStore: SensitiveFlagStore? = nil) throws -> [Clip] {
        guard limit > 0 else { return [] }
        let regex = try rule.textPattern.map { pattern -> NSRegularExpression in
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                throw SmartCollectionError.invalidPattern
            }
            return compiled
        }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        if !rule.kinds.isEmpty {
            let stored = Set(rule.kinds.map { $0.storedContentKind.rawValue }).sorted()
            clauses.append("contentKind IN (\(stored.map { _ in "?" }.joined(separator: ", ")))")
            args.append(contentsOf: stored)
        }
        if let app = rule.sourceApp?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            let escaped = app.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            clauses.append("(COALESCE(sourceAppName, '') LIKE ? ESCAPE '\\' OR COALESCE(sourceAppBundleID, '') LIKE ? ESCAPE '\\')")
            args.append(contentsOf: ["%\(escaped)%", "%\(escaped)%"])
        }
        if let days = rule.olderThanDays {
            clauses.append("createdAt < ?")
            args.append(now.addingTimeInterval(-Double(days) * 86_400))
        }
        if let days = rule.newerThanDays {
            clauses.append("createdAt >= ?")
            args.append(now.addingTimeInterval(-Double(days) * 86_400))
        }
        let sql = "SELECT * FROM clips" + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "))
            + " ORDER BY createdAt DESC, id DESC LIMIT ? OFFSET ?"
        let pageSize = 200
        return try dbQueue.read { db in
            var found: [Clip] = []
            var offset = 0
            while found.count < limit {
                let page = try Clip.fetchAll(db, sql: sql, arguments: StatementArguments(args + [pageSize, offset]))
                for clip in page where Self.satisfies(clip, rule, regex, sensitiveStore) {
                    found.append(clip)
                    if found.count == limit { break }
                }
                guard page.count == pageSize else { break }
                offset += page.count
            }
            return found
        }
    }

    private static func satisfies(_ clip: Clip, _ rule: SmartCollectionRule, _ regex: NSRegularExpression?,
                                  _ store: SensitiveFlagStore?) -> Bool {
        if !rule.kinds.isEmpty, !rule.kinds.contains(where: { $0.matches(clip) }) { return false }
        if let wanted = rule.sensitive, SensitiveContent.isSensitive(clip: clip, store: store) != wanted { return false }
        if let regex {
            let candidates = [clip.contentText, clip.ocrText ?? ""]
            let hit = candidates.contains { text in
                let scanned = String(text.prefix(smartRuleScanLimit))
                return regex.firstMatch(in: scanned, range: NSRange(scanned.startIndex..., in: scanned)) != nil
            }
            if !hit { return false }
        }
        return true
    }

    private static func smartCollection(_ row: Row) -> SmartCollection? {
        let json: String = row["rule"]
        guard let rule = try? JSONDecoder().decode(SmartCollectionRule.self, from: Data(json.utf8)) else { return nil }
        return SmartCollection(id: row["id"], name: row["name"], rule: rule, sortOrder: row["sortOrder"])
    }
}
