import Foundation
import GRDB

/// One search result and where it matched.
struct SearchHit: Equatable {
    let clip: Clip
    let matchedIn: SearchMatchLocation
}

/// Results of `ClipDatabase.search` plus everything the UI should tell the user.
struct SearchOutcome: Equatable {
    var hits: [SearchHit]
    /// Parse warnings plus database-level ones (for example an unknown category).
    var warnings: [QueryWarning]

    var clips: [Clip] { hits.map(\.clip) }
}

extension ClipDatabase {
    /// Searches clips with the grammar documented in ClipSearchQuery.swift.
    func searchClips(matching query: String, limit: Int) throws -> [Clip] {
        try search(matching: query, limit: limit).clips
    }

    /// Full search: free text and phrases go through FTS5 (clip text, title and
    /// OCR text), everything else is SQL. Derived kinds (`#link`...) and their
    /// negations finish in Swift, paging until `limit` results or exhaustion.
    /// Filter-only queries are ordered newest-first; text queries by FTS rank.
    func search(matching query: String, limit: Int, now: Date = Date(),
                calendar: Calendar = .current) throws -> SearchOutcome {
        let parsed = ClipQueryParser.parse(query, now: now, calendar: calendar)
        guard limit > 0 else { return SearchOutcome(hits: [], warnings: parsed.warnings) }
        let needsPostFilter = parsed.kinds.contains(where: \.isDerived) || parsed.excludedKinds.contains(where: \.isDerived)
        return try dbQueue.read { db in
            var warnings = parsed.warnings
            let plan = try Self.plan(parsed, db: db, warnings: &warnings)
            let pageSize = needsPostFilter ? Swift.max(limit * 4, 200) : limit
            var found: [Clip] = []
            var offset = 0
            while found.count < limit {
                // Ids first: the ORDER BY sorter then carries an id and a rank,
                // not every matching row's full text (10k FTS hits copied whole
                // was the dominant cost). Hydrate just the page afterwards.
                let ids = try Int64.fetchAll(
                    db, sql: plan.sql + " LIMIT ? OFFSET ?",
                    arguments: StatementArguments(plan.arguments + [pageSize as DatabaseValueConvertible, offset]))
                let byID = Dictionary(uniqueKeysWithValues: try Clip.fetchAll(db, keys: ids).compactMap { clip in
                    clip.id.map { ($0, clip) }
                })
                let page = ids.compactMap { byID[$0] }
                for clip in page where Self.passesKindFilter(clip, parsed) {
                    found.append(clip)
                    if found.count == limit { break }
                }
                guard needsPostFilter, ids.count == pageSize else { break }
                offset += ids.count
            }
            return SearchOutcome(hits: found.map { SearchHit(clip: $0, matchedIn: Self.matchLocation($0, parsed)) },
                                 warnings: warnings)
        }
    }

    private struct SearchPlan {
        var sql: String
        var arguments: [DatabaseValueConvertible]
    }

    private static func passesKindFilter(_ clip: Clip, _ parsed: ParsedQuery) -> Bool {
        if !parsed.kinds.isEmpty, !parsed.kinds.contains(where: { $0.matches(clip) }) { return false }
        return !parsed.excludedKinds.contains(where: { $0.matches(clip) })
    }

    /// `.ocr` only when the clip has recognised text and the query is not fully
    /// explained by the clip's own text or title.
    private static func matchLocation(_ clip: Clip, _ parsed: ParsedQuery) -> SearchMatchLocation {
        let terms = parsed.highlightTerms
        guard !terms.isEmpty, let ocr = clip.ocrText, !ocr.isEmpty else { return .text }
        let body = String(clip.contentText.prefix(100_000))
        let title = clip.userTitle ?? ""
        if terms.allSatisfy({ SearchHighlight.contains(body, $0) || SearchHighlight.contains(title, $0) }) {
            return terms.allSatisfy({ SearchHighlight.contains(body, $0) }) ? .text : .title
        }
        return .ocr
    }

    private static func plan(_ parsed: ParsedQuery, db: Database, warnings: inout [QueryWarning]) throws -> SearchPlan {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        var joinFTS = false

        // Positive text: a single MATCH so rank ordering works.
        var positives: [String] = []
        if !parsed.text.isEmpty, let pattern = FTS5Pattern(matchingAllPrefixesIn: parsed.text) {
            positives.append("(\(pattern.rawPattern))")
        }
        for phrase in parsed.phrases {
            if let pattern = FTS5Pattern(matchingPhrase: phrase) { positives.append("(\(pattern.rawPattern))") }
        }
        if !positives.isEmpty {
            joinFTS = true
            clauses.append("clips_fts MATCH ?")
            args.append(positives.joined(separator: " AND "))
        }
        var negatives: [FTS5Pattern] = parsed.excludedTerms.compactMap { FTS5Pattern(matchingAllPrefixesIn: $0) }
        negatives += parsed.excludedPhrases.compactMap { FTS5Pattern(matchingPhrase: $0) }
        for pattern in negatives {
            clauses.append("clips.id NOT IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
            args.append(pattern)
        }

        if !parsed.kinds.isEmpty {
            let stored = Set(parsed.kinds.map { $0.storedContentKind.rawValue }).sorted()
            clauses.append("clips.contentKind IN (\(placeholders(stored.count)))")
            args.append(contentsOf: stored)
        }
        let excludedStored = parsed.excludedKinds.filter { !$0.isDerived }.map { $0.storedContentKind.rawValue }.sorted()
        if !excludedStored.isEmpty {
            clauses.append("clips.contentKind NOT IN (\(placeholders(excludedStored.count)))")
            args.append(contentsOf: excludedStored)
        }

        if !parsed.sourceApps.isEmpty {
            clauses.append("(" + parsed.sourceApps.map { _ in appPredicate }.joined(separator: " OR ") + ")")
            for app in parsed.sourceApps { args.append(contentsOf: [likePattern(app), likePattern(app)]) }
        }
        for app in parsed.excludedApps {
            clauses.append("NOT \(appPredicate)")
            args.append(contentsOf: [likePattern(app), likePattern(app)])
        }

        try addCategoryClauses(parsed, db: db, clauses: &clauses, args: &args, warnings: &warnings)

        if let since = parsed.since {
            clauses.append("clips.createdAt >= ?")
            args.append(since)
        }
        if let until = parsed.until {
            clauses.append("clips.createdAt < ?")
            args.append(until)
        }
        for size in parsed.sizeConstraints {
            clauses.append("COALESCE(clips.byteSize, LENGTH(CAST(clips.contentText AS BLOB))) \(size.op.rawValue) ?")
            args.append(size.bytes)
        }

        var sql = "SELECT clips.id FROM clips"
        if joinFTS { sql += " JOIN clips_fts ON clips_fts.rowid = clips.id" }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += joinFTS ? " ORDER BY rank, clips.id DESC" : " ORDER BY clips.createdAt DESC, clips.id DESC"
        return SearchPlan(sql: sql, arguments: args)
    }

    private static let appPredicate =
        "(COALESCE(clips.sourceAppName, '') LIKE ? ESCAPE '\\' OR COALESCE(clips.sourceAppBundleID, '') LIKE ? ESCAPE '\\')"

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// `%value%` with LIKE wildcards in the value escaped.
    private static func likePattern(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private static func addCategoryClauses(
        _ parsed: ParsedQuery, db: Database, clauses: inout [String],
        args: inout [DatabaseValueConvertible], warnings: inout [QueryWarning]
    ) throws {
        guard !parsed.categories.isEmpty || !parsed.excludedCategories.isEmpty else { return }
        let known = try Row.fetchAll(db, sql: "SELECT id, name FROM category")
        func ids(_ names: [String]) -> [Int64] {
            names.flatMap { name in
                known.filter { ($0["name"] as String).caseInsensitiveCompare(name) == .orderedSame }
                    .map { $0["id"] as Int64 }
            }
        }
        for name in parsed.categories + parsed.excludedCategories where ids([name]).isEmpty {
            warnings.append(QueryWarning(kind: .unknownCategory, token: name))
        }
        func member(_ count: Int) -> String {
            "clips.id IN (SELECT clipID FROM clip_category WHERE categoryID IN (\(placeholders(count))))"
        }
        if !parsed.categories.isEmpty {
            let included = ids(parsed.categories)
            if included.isEmpty {
                clauses.append("0")
            } else {
                clauses.append(member(included.count))
                args.append(contentsOf: included)
            }
        }
        let excluded = ids(parsed.excludedCategories)
        if !excluded.isEmpty {
            clauses.append("NOT " + member(excluded.count))
            args.append(contentsOf: excluded)
        }
    }
}
