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
        let needsDerivedFilter = parsed.kinds.contains(where: \.isDerived) || parsed.excludedKinds.contains(where: \.isDerived)
        return try dbQueue.read { db in
            var warnings = parsed.warnings
            let plan = try Self.plan(parsed, db: db, warnings: &warnings)
            let needsPostFilter = needsDerivedFilter || !plan.residual.isEmpty
            let pageSize = needsPostFilter ? Swift.max(limit * 4, 200) : limit
            var found: [Clip] = []
            var tier = 0
            var offset = 0
            // Ids first: the ORDER BY sorter then carries an id, not every
            // matching row's full text (10k FTS hits copied whole was the dominant
            // cost). Hydrate just the page afterwards. Tiers are read in order
            // and the second only when the first ran dry, so a plain word with
            // enough whole-word matches never pays for the fragment scan.
            func nextIDs(_ count: Int) throws -> [Int64] {
                var ids: [Int64] = []
                while ids.count < count, tier < plan.tiers.count {
                    let step = plan.tiers[tier]
                    let want = count - ids.count
                    let got = try Int64.fetchAll(
                        db, sql: step.sql + " LIMIT ? OFFSET ?",
                        arguments: StatementArguments(step.arguments + [want as DatabaseValueConvertible, offset]))
                    ids += got
                    if got.count < want { tier += 1; offset = 0 } else { offset += got.count }
                }
                return ids
            }
            while found.count < limit {
                let ids = try nextIDs(pageSize)
                let byID = Dictionary(uniqueKeysWithValues: try Clip.fetchLight(db, ids: ids).compactMap { clip in
                    clip.id.map { ($0, clip) }
                })
                let page = ids.compactMap { byID[$0] }
                for clip in page where Self.passesKindFilter(clip, parsed) && Self.passesResidual(clip, plan.residual) {
                    found.append(clip)
                    if found.count == limit { break }
                }
                guard needsPostFilter, ids.count == pageSize else { break }
            }
            return SearchOutcome(hits: found.map { SearchHit(clip: $0, matchedIn: Self.matchLocation($0, parsed)) },
                                 warnings: warnings)
        }
    }

    private struct SearchStatement {
        var sql: String
        var arguments: [DatabaseValueConvertible]
    }

    /// Terms SQL could not carry (past the per-query cap, or too long for a LIKE
    /// pattern); the Swift side checks them on the hydrated page.
    private struct ResidualTerms {
        var needed: [String] = []
        var forbidden: [String] = []
        var isEmpty: Bool { needed.isEmpty && forbidden.isEmpty }
    }

    /// `tiers` are read in order: whole-word matches, then the rest (newest first
    /// within each). A single tier when the query has no word tier.
    private struct SearchPlan {
        var tiers: [SearchStatement]
        var residual: ResidualTerms
    }

    /// SQLite rejects deep expression trees (default depth 1000) and LIKE patterns
    /// over 50,000 bytes, so a pasted paragraph used to throw. SQL narrows with at
    /// most this many terms of each sign, each needle cut to the length below; the
    /// remainder is verified in Swift against the full text.
    private static let maxSQLTerms = 12
    private static let maxNeedleLength = 512

    private static func passesResidual(_ clip: Clip, _ residual: ResidualTerms) -> Bool {
        guard !residual.isEmpty else { return true }
        let haystacks = [clip.contentText, clip.userTitle ?? "", clip.ocrText ?? ""]
        func has(_ needle: String) -> Bool { haystacks.contains { SearchHighlight.contains($0, needle) } }
        return residual.needed.allSatisfy(has) && !residual.forbidden.contains(where: has)
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
        var residual = ResidualTerms()
        var textClauses: [String] = []
        var textArgs: [DatabaseValueConvertible] = []
        var carried = 0
        var wordPatterns: [String] = []
        func addPositive(_ needle: String, _ pattern: FTS5Pattern?) {
            if carried >= maxSQLTerms {
                residual.needed.append(needle)
                return
            }
            carried += 1
            if needle.count > maxNeedleLength {
                residual.needed.append(needle)
                textClauses.append(containsClause(nil, String(needle.prefix(maxNeedleLength)), &textArgs))
                return
            }
            if let pattern { wordPatterns.append("(\(pattern.rawPattern))") }
            textClauses.append(containsClause(pattern, needle, &textArgs))
        }
        for word in words { addPositive(word, wordPattern(word)) }
        for phrase in parsed.phrases { addPositive(phrase, phrasePattern(phrase)) }

        var filterClauses: [String] = []
        var filterArgs: [DatabaseValueConvertible] = []
        var excludedCarried = 0
        func addExcluded(_ needle: String, _ pattern: FTS5Pattern?) {
            // An exclusion cut short would drop clips that only share the prefix,
            // so over-long or surplus ones are decided in Swift alone.
            if excludedCarried >= maxSQLTerms || needle.count > maxNeedleLength {
                residual.forbidden.append(needle)
                return
            }
            excludedCarried += 1
            filterClauses.append("NOT " + containsClause(pattern, needle, &filterArgs))
        }
        for word in parsed.excludedTerms { addExcluded(word, wordPattern(word)) }
        for phrase in parsed.excludedPhrases { addExcluded(phrase, phrasePattern(phrase)) }

        if !parsed.kinds.isEmpty {
            let stored = Set(parsed.kinds.map { $0.storedContentKind.rawValue }).sorted()
            filterClauses.append("clips.contentKind IN (\(placeholders(stored.count)))")
            filterArgs.append(contentsOf: stored)
        }
        let excludedStored = parsed.excludedKinds.filter { !$0.isDerived }.map { $0.storedContentKind.rawValue }.sorted()
        if !excludedStored.isEmpty {
            filterClauses.append("clips.contentKind NOT IN (\(placeholders(excludedStored.count)))")
            filterArgs.append(contentsOf: excludedStored)
        }

        if !parsed.sourceApps.isEmpty {
            filterClauses.append("(" + parsed.sourceApps.map { _ in appPredicate }.joined(separator: " OR ") + ")")
            for app in parsed.sourceApps { filterArgs.append(contentsOf: [likePattern(app), likePattern(app)]) }
        }
        for app in parsed.excludedApps {
            filterClauses.append("NOT \(appPredicate)")
            filterArgs.append(contentsOf: [likePattern(app), likePattern(app)])
        }

        try addCategoryClauses(parsed, db: db, clauses: &filterClauses, args: &filterArgs, warnings: &warnings)

        if let since = parsed.since {
            filterClauses.append("clips.createdAt >= ?")
            filterArgs.append(since)
        }
        if let until = parsed.until {
            filterClauses.append("clips.createdAt < ?")
            filterArgs.append(until)
        }
        for size in parsed.sizeConstraints {
            filterClauses.append("COALESCE(clips.byteSize, LENGTH(CAST(clips.contentText AS BLOB))) \(size.op.rawValue) ?")
            filterArgs.append(size.bytes)
        }

        // Every term of the word tier starts a word in the FTS index; a term with
        // punctuation (or none left in SQL) has no pattern and so no tier.
        let tierPattern = !textClauses.isEmpty && wordPatterns.count == textClauses.count
            ? wordPatterns.joined(separator: " AND ") : nil
        let order = " ORDER BY clips.createdAt DESC, clips.id DESC"
        func statement(_ clauses: [String], _ args: [DatabaseValueConvertible]) -> SearchStatement {
            var sql = "SELECT clips.id FROM clips"
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            return SearchStatement(sql: sql + order, arguments: args)
        }
        guard let tierPattern else {
            return SearchPlan(tiers: [statement(textClauses + filterClauses, textArgs + filterArgs)], residual: residual)
        }
        // Clips where every word starts a word rank above fragment-only matches;
        // within each tier the newest clip comes first, which is what a clipboard
        // history is for (bm25 used to float a weeks-old one-liner above the clip
        // copied a minute ago). The first tier is driven by the FTS index alone, so
        // its cost follows the matches, not the table; the second is the LIKE scan,
        // which can walk createdAt order and stop at the page size.
        let inTier = "clips.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)"
        let first = statement([inTier] + filterClauses, [tierPattern as DatabaseValueConvertible] + filterArgs)
        let rest = statement(
            textClauses + ["clips.id NOT IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)"] + filterClauses,
            textArgs + [tierPattern as DatabaseValueConvertible] + filterArgs)
        return SearchPlan(tiers: [first, rest], residual: residual)
    }

    /// FTS5 prefix pattern for a plain word. A word with punctuation in it
    /// ("c++", "w159/clip", "jo@x") gets none: the tokenizer would split it into
    /// loose prefixes ("c*" matches every word starting with c), so it is matched
    /// literally as a fragment instead.
    private static func wordPattern(_ word: String) -> FTS5Pattern? {
        guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return FTS5Pattern(matchingAllPrefixesIn: word)
    }

    /// FTS5 phrase pattern, or nil when the phrase has anything but letters,
    /// digits and spaces: the tokenizer would turn `"c++"` into the phrase `c`
    /// and `"user_name"` into `user name`, so those match literally instead.
    private static func phrasePattern(_ phrase: String) -> FTS5Pattern? {
        guard phrase.allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace }) else { return nil }
        return FTS5Pattern(matchingPhrase: phrase)
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
