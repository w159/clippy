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

    /// Full search: free text and phrases match the clip text, title and OCR text
    /// (FTS5 word prefixes plus LIKE fragments), everything else is SQL. Derived
    /// kinds (`#link`...) and their negations finish in Swift, paging until
    /// `limit` results or exhaustion. Ordering: whole-word matches first, then
    /// fragment matches, newest first within each.
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

        // Free text: every word and phrase must occur in the clip's text, title
        // or recognised text. A word matches as the start of a word through the
        // FTS5 index (case and diacritic insensitive, so "inv" finds "Invoice"
        // and "cafe" finds its accented spelling) or anywhere as a fragment through LIKE, so
        // "hub" finds "github", "Name" finds "getUserName" and "@" or "c++" find
        // themselves. Punctuation-only text used to be dropped and returned
        // every clip; it is now a literal fragment like any other word.
        let words = parsed.text.split(separator: " ").map(String.init)
        var wordPatterns: [String] = []
        for word in words {
            let pattern = wordPattern(word)
            if let pattern { wordPatterns.append("(\(pattern.rawPattern))") }
            clauses.append(containsClause(pattern, word, &args))
        }
        for phrase in parsed.phrases {
            let pattern = FTS5Pattern(matchingPhrase: phrase)
            if let pattern { wordPatterns.append("(\(pattern.rawPattern))") }
            clauses.append(containsClause(pattern, phrase, &args))
        }
        for word in parsed.excludedTerms {
            clauses.append("NOT " + containsClause(wordPattern(word), word, &args))
        }
        for phrase in parsed.excludedPhrases {
            clauses.append("NOT " + containsClause(FTS5Pattern(matchingPhrase: phrase), phrase, &args))
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
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        // Clips where every word starts a word rank above fragment-only matches;
        // within each tier the newest clip comes first, which is what a clipboard
        // history is for (bm25 used to float a weeks-old one-liner above the clip
        // copied a minute ago).
        sql += " ORDER BY "
        if words.count + parsed.phrases.count == wordPatterns.count, !wordPatterns.isEmpty {
            sql += "(clips.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)) DESC, "
            args.append(wordPatterns.joined(separator: " AND "))
        }
        sql += "clips.createdAt DESC, clips.id DESC"
        return SearchPlan(sql: sql, arguments: args)
    }

    /// FTS5 prefix pattern for a plain word. A word with punctuation in it
    /// ("c++", "w159/clip", "jo@x") gets none: the tokenizer would split it into
    /// loose prefixes ("c*" matches every word starting with c), so it is matched
    /// literally as a fragment instead.
    private static func wordPattern(_ word: String) -> FTS5Pattern? {
        guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return FTS5Pattern(matchingAllPrefixesIn: word)
    }

    /// True when the clip contains `needle`: as a word prefix through the FTS5
    /// index when `pattern` exists, else (or also) as a LIKE fragment of the text,
    /// title or OCR text. The IN subquery is uncorrelated, so SQLite builds it once
    /// per search and LIKE only runs on rows the index did not already match.
    private static func containsClause(_ pattern: FTS5Pattern?, _ needle: String,
                                       _ args: inout [DatabaseValueConvertible]) -> String {
        var options: [String] = []
        if let pattern {
            options.append("clips.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
            args.append(pattern)
        }
        let like = likePattern(needle)
        options.append("clips.contentText LIKE ? ESCAPE '\\'")
        options.append("COALESCE(clips.userTitle, '') LIKE ? ESCAPE '\\'")
        options.append("COALESCE(clips.ocrText, '') LIKE ? ESCAPE '\\'")
        args.append(contentsOf: [like, like, like])
        return "(" + options.joined(separator: " OR ") + ")"
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
