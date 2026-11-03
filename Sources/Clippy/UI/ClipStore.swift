import Combine
import Foundation
import GRDB

#if canImport(AppKit)
    import AppKit
#endif

/// Lifecycle of the Smart Suggestions pane.
enum SuggestionsState: Equatable {
    case disabled, needsPermission, loading, ready, empty
}

/// View model for the panel: live observation of clips, categories, and
/// membership; FTS5 search when a query is typed. "Pinned" is derived:
/// a clip is pinned when it belongs to at least one category.
@MainActor
final class ClipStore: ObservableObject {
    @Published var query: String = "" {
        didSet { scheduleRefilter() }
    }
    /// Widened from private(set): ClipStore+Older (paged history) appends to it.
    @Published var clips: [Clip] = []
    /// Clips loaded past the resident window by `loadOlder(before:limit:)`, newest
    /// first, appended to `clips` in browse mode. Dropped by `resetOlder()`.
    @Published var olderClips: [Clip] = []
    /// False once `loadOlder` reached the oldest clip.
    @Published var hasMoreOlder = true
    @Published private(set) var categories: [Category] = []
    @Published private(set) var membership: [Int64: Set<Int64>] = [:] {
        didSet { categoryPaneVersion &+= 1 }
    }
    /// Per-category ordered clip ID lists, keyed by categoryID.
    /// Reflects clip_category.sortOrder so category panes can present clips
    /// in user-defined order rather than global createdAt order.
    @Published var categoryClipOrder: [Int64: [Int64]] = [:] {
        didSet { categoryPaneVersion &+= 1 }
    }
    /// Last search failure. Non-nil triggers an error banner with Retry in the
    /// panel. Cleared on the next successful search or when the query empties.
    @Published var searchError: String?
    /// Trimmed query whose results are in `clips`. Lags `query` while a search
    /// is debounced or running; `hasPendingSearch` compares the two so Return
    /// pressed mid-typing can wait for the results it means instead of pasting
    /// the previous query's top clip.
    @Published private(set) var completedQuery = ""
    /// Last DB observation failure. Non-nil triggers an error banner with a
    /// Retry that re-starts the ValueObservation pipelines.
    @Published var observationError: String?
    /// Clip IDs with OCR (Extract Text) currently in flight. Lives on the store,
    /// not view state, because PanelController.show() builds a fresh ClipListView
    /// per presentation — view @State would drop both the spinner and the
    /// double-run guard if the panel is closed and reopened mid-recognition.
    ///
    /// OCR-05: this whole-store set still invalidates every observer on each OCR
    /// start/finish. New code should observe `ocrProgress(for:)` instead, which
    /// invalidates only the affected card; callers migrate off this set over time.
    @Published var ocrInFlightClipIDs: Set<Int64> = []
    /// Per-clip OCR state, created on demand (see ClipStore+OCR.swift).
    var ocrProgressByClip: [Int64: OCRProgress] = [:]
    /// Identity of the OCR run currently owning each clip; a completion whose
    /// token no longer matches was cancelled and must not write anything.
    var ocrRunTokens: [Int64: UUID] = [:]
    /// Last category create/rename/delete failure (DAT-14) or failed background
    /// write (pin, delete, rename, filing; see `performWrite`). UI shows it as a
    /// banner and clears it.
    @Published var categoryError: String?
    /// Last "load older" page failure. Loaded rows are kept; the list foot shows
    /// this with a Retry that calls `loadOlder` again. Cleared on the next success.
    @Published var olderLoadError: String?
    /// Non-nil when the clip table is at or above 90% of the configured ceiling (DAT-06).
    @Published private(set) var storageWarning: StorageUsage?

    /// Ranked Smart Suggestions for the current screen context (or a
    /// "Find Similar" clip). In memory only; dropped when the panel hides.
    @Published var suggestions: [Suggestion] = []
    @Published var suggestionsState: SuggestionsState = .disabled
    /// Human summary shown in the pane header. Never raw screen text.
    @Published var suggestionsContextSummary: String?

    var recents: [Clip] = [] {
        didSet {
            // The observation window is re-published for any write to clips (OCR
            // every ~2 s, each capture). An identical window changes nothing the
            // list or an active search shows, so it must not restart the search.
            guard recents != oldValue else { return }
            categoryPaneVersion &+= 1
            // Rebuilt once per observation pulse instead of once per
            // clipsForCategory call: the id lookup is hit several times per
            // redraw (sections, metadata, keyboard handling all query it).
            recentsByID = Dictionary(
                uniqueKeysWithValues: recents.compactMap { clip in
                    clip.id.map { ($0, clip) }
                })
            refilter()
            pruneOlder()
        }
    }
    /// id -> clip lookup over `recents`, kept in sync by `recents.didSet`.
    var recentsByID: [Int64: Clip] = [:]
    /// Decodes the observed window incrementally (see ClipWindowLoader).
    let windowLoader = ClipWindowLoader()
    private var searchDebounce: Task<Void, Never>?
    /// The in-flight FTS read, cancelled whenever the query or window changes.
    private var searchTask: Task<Void, Never>?
    /// Monotonic generation for the async FTS search. Incremented on every
    /// refilter that kicks off a background read; the completion discards
    /// results from any earlier generation so a fast-typed query or a DB pulse
    /// mid-search cannot overwrite the current results with stale ones.
    var refilterToken = 0
    /// Where each semantic-merged hit came from (search pass 2); empty unless the semantic opt-in produced results.
    /// Deliberately not @Published: views read it together with `clips`, which is republished on any change.
    var semanticMatches: [Int64: SearchMatchSource] = [:] {
        didSet { semanticMatchesAssignCount += 1 }
    }
    /// Test seam: how many times `semanticMatches` was assigned, so a pulse that clears and restores badges is visible.
    private(set) var semanticMatchesAssignCount = 0
    /// Runs the keyword search off the main actor. A seam so tests can make it fail.
    typealias SearchRunner = @Sendable (ClipDatabase, String, Int) throws -> [Clip]
    var searchRunner: SearchRunner = { database, query, limit in
        try database.searchClips(matching: query, limit: limit)
    }
    /// Gate and engine of the semantic pass; replaced in tests.
    var semanticEnvironment = SemanticSearchEnvironment.standard
    /// The in-flight semantic merge; cancelled by every new search so overlapping
    /// runs do not each load and embed the candidate pool.
    var semanticTask: Task<Void, Never>?
    /// Generation of the newest merge. A merge whose id is no longer current drops
    /// its result even if it finished before the cancel reached it.
    var semanticRunID = 0
    /// Highest merge generation that finished (published or fell back).
    var semanticCompletedRunID = 0
    /// Trimmed query whose fused (keyword plus semantic) order is on screen. While
    /// it matches the query being refreshed, a DB pulse keeps that order up
    /// instead of flashing the keyword-only one.
    var fusedQuery: String?
    /// Bumped whenever the inputs of `clipsForCategory` change.
    var categoryPaneVersion = 0
    /// Filtered category-pane results for one query and data version.
    var categoryPaneCache: (query: String, version: Int, results: [Int64: [Clip]])?
    /// The query last parsed for category-pane filtering, with when it was parsed
    /// (relative dates such as `#yesterday` move with the clock).
    var localQueryParse: (query: String, parsed: ParsedQuery, at: Date)?
    /// How many times a category-pane query was parsed; observable in tests.
    var localQueryParseCount = 0
    /// Generation for async suggestion ranking; stale completions are dropped.
    var suggestionsToken = 0
    private var clipsCancellable: AnyDatabaseCancellable?
    private var categoriesCancellable: AnyDatabaseCancellable?
    let database: ClipDatabase
    let monitor: ClipboardMonitor?
    /// Pasteboard the OCR result is written to. Injectable for tests so
    /// the suppression test can use a scratch pasteboard instead of the
    /// real one (mirrors ClipboardMonitor's pasteboard seam).
    let pasteboard: NSPasteboard
    /// Text recognizer used by `extractText`; must call its completion on the
    /// main queue (as `OCRService.recognizeText` does). Injectable so tests can
    /// stub Vision, which is slow/flaky when cold on CI runners.
    let recognizer: (URL, @escaping @MainActor (OCRService.RecognitionResult) -> Void) -> Void
    let displayLimit = 300
    /// Serial lane for mutation writes. The shared DatabaseQueue serializes all
    /// access, so a synchronous write from the main thread stalls the UI while
    /// a capture write or iCloud export holds the queue (reads already moved
    /// off-main in refilter). One serial queue, not .global, so rapid mutations
    /// such as successive drag-reorders apply in the order they were issued.
    /// The GRDB ValueObservation republishes state after each write, so the UI
    /// never needs to wait on the write itself.
    private let writeQueue = DispatchQueue(
        label: "com.clippy.ClipStore.writes", qos: .userInitiated)

    /// - Parameters:
    ///   - database: shared clip database.
    ///   - monitor: clipboard monitor, when supplied, is used to suppress
    ///     re-capturing Clippy's own OCR pasteboard write.
    init(
        database: ClipDatabase,
        monitor: ClipboardMonitor? = nil,
        pasteboard: NSPasteboard = .general,
        recognizer: @escaping (URL, @escaping @MainActor (OCRService.RecognitionResult) -> Void) -> Void = {
            OCRService.recognizeText(in: $0, completion: $1)
        }
    ) {
        self.database = database
        self.monitor = monitor
        self.pasteboard = pasteboard
        self.recognizer = recognizer
        startObservations()
    }

    /// (Re)start both ValueObservation pipelines. Called once from init and again
    /// from retryObservation() when a prior pipeline failed and the user taps
    /// Retry. Cancels any existing cancellables first so it is idempotent.
    private func startObservations() {
        clipsCancellable?.cancel()
        categoriesCancellable?.cancel()
        let limit = displayLimit
        // Two observations on purpose: clips churn on every copy, while categories
        // and membership change rarely; separating them avoids refetching the clip
        // window for every category edit.
        // Recents window plus every categorized clip: categorized clips must
        // stay visible in their panes even when older than the window. The
        // loader decodes only rows that changed since the previous pulse.
        let loader = windowLoader
        let database = database
        let clipObservation = ValueObservation.tracking(
            // Explicit: a pulse with no changed rows reads only id and rowVersion,
            // and a region inferred from that read would be narrower than the window.
            region: Table("clips"), Table("clip_category"), Table("clip_version"),
            fetch: { db in try loader.load(db, limit: limit, generation: database.contentGeneration) }
        )
        // Identical windows (a write that touched nothing the list shows) are dropped
        // on the observation queue, not compared and republished on the main thread.
        .removeDuplicates()
        // Initial count + list fetch are deliberately scheduled away from the
        // main thread: opening the panel must not wait for SQLite. The first
        // observation is published as soon as it completes.
        clipsCancellable = clipObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: DispatchQueue.global(qos: .userInitiated)),
            onError: { [weak self] error in
                ClippyLog.error("Clip observation failed: \(error)", category: ClippyLog.storage)
                DispatchQueue.main.async { self?.observationError = error.localizedDescription }
            },
            onChange: { [weak self] window in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.observationError = nil
                    self.recents = window.clips
                    let usage = StorageUsage(count: window.total, ceiling: StorageCeiling.current)
                    let warning = usage.isNearCeiling ? usage : nil
                    if self.storageWarning != warning { self.storageWarning = warning }
                }
            }
        )

        let categoryObservation = ValueObservation.tracking {
            db -> ([Category], [Int64: Set<Int64>], [Int64: [Int64]]) in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(
                db)
            let map = try ClipDatabase.buildMembershipMap(db)
            // Load per-category clip order from clip_category.sortOrder.
            let orderRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT categoryID, clipID
                    FROM clip_category
                    ORDER BY categoryID ASC, sortOrder ASC, addedAt DESC
                    """
            )
            var order: [Int64: [Int64]] = [:]
            for row in orderRows {
                let catID: Int64 = row["categoryID"]
                let clipID: Int64 = row["clipID"]
                order[catID, default: []].append(clipID)
            }
            return (categories, map, order)
        }
        categoriesCancellable = categoryObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                ClippyLog.error(
                    "Category observation failed: \(error)", category: ClippyLog.storage)
                DispatchQueue.main.async { self?.observationError = error.localizedDescription }
            },
            onChange: { [weak self] categories, map, order in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.observationError = nil
                    self.categories = categories
                    self.membership = map
                    self.categoryClipOrder = order
                }
            }
        )
    }

    /// Re-run the search immediately. Bound to the Retry button on the search
    /// error banner; clears the error if the search now succeeds.
    func retrySearch() {
        refilter()
    }

    /// Tear down and re-start the DB observation pipelines. Bound to the Retry
    /// button on the observation error banner.
    func retryObservation() {
        observationError = nil
        startObservations()
    }

    // MARK: - Memory pressure

    /// Drop the in-memory clip array back to a small resident window so the OS
    /// can reclaim the Swift heap during a critical memory-pressure event. The
    /// DB is the source of truth; the GRDB observation will repopulate `recents`
    /// on the next write (which clears the pressure anyway). Safe to call from
    /// the main thread only.
    func trimResident() {
        // Keep only the 50 most-recent clips resident; categorized clips that
        // fall outside the window will reappear on the next DB observation pulse.
        let trimLimit = 50
        if recents.count > trimLimit {
            recents = Array(recents.prefix(trimLimit))
            ClippyLog.info(
                "trimResident: reduced resident clips to \(trimLimit)",
                category: ClippyLog.storage)
        }
    }

    // MARK: - Actions

    /// Shown when a background write fails.
    static let writeFailureMessage = "Couldn't save that change. Try again."

    /// Enqueue a DB mutation on the serial write lane. A failure is logged and
    /// published once on `categoryError`, which the panel shows as a banner.
    func performWrite(_ label: String, _ body: @escaping () throws -> Void) {
        writeQueue.async { [weak self] in
            do {
                try body()
            } catch {
                ClippyLog.error("\(label) failed: \(error)", category: ClippyLog.storage)
                DispatchQueue.main.async { self?.reportWriteFailure() }
            }
        }
    }

    /// Publishes a write failure for the panel banner (the `categoryError` path).
    func reportWriteFailure(_ message: String = ClipStore.writeFailureMessage) {
        categoryError = message
    }

    /// Toggles membership in the starter category (the Cmd+P fast path).
    func togglePin(_ clip: Clip) {
        guard let id = clip.id else { return }
        performWrite("togglePin") { [database] in
            try database.toggleStarterMembership(clipID: id)
        }
    }

    func setClip(_ clip: Clip, inCategory categoryID: Int64, _ isMember: Bool) {
        guard let id = clip.id else { return }
        performWrite("setClip") { [database] in
            try database.setClip(id, inCategory: categoryID, isMember)
        }
    }

    func addClip(id clipID: Int64, toCategory categoryID: Int64) {
        performWrite("addClip") { [database] in
            try database.setClip(clipID, inCategory: categoryID, true)
        }
    }

    /// Files a clip into `categoryID`, honoring the single-vs-multiple setting.
    /// When multiple categories are disallowed (default), the clip is first
    /// removed from every other category so it lives in exactly one.
    func fileClip(id clipID: Int64, intoCategory categoryID: Int64) {
        // Snapshot the memberships on the main thread (`membership` is
        // @Published), then run removals + add as one enqueued unit so another
        // mutation cannot interleave between them.
        let others =
            AppSettings.shared.allowMultipleCategories
            ? []
            : (membership[clipID] ?? []).subtracting([categoryID])
        performWrite("fileClip") { [database] in
            try database.fileClip(clipID, into: categoryID, leaving: others)
        }
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        if olderClips.contains(where: { $0.id == id }) {
            olderClips.removeAll { $0.id == id }
            refilter()
        }
        performWrite("deleteClip") { [database] in
            try database.deleteClip(id: id)
            ClipSpotlightIndexer.remove(clipID: id)
        }
    }

    /// Debounced entry from `query.didSet`. An empty query refilters
    /// immediately (so clearing search feels instant); a non-empty query waits
    /// ~180ms for the user to stop typing, coalescing rapid keystrokes into one
    /// FTS5 read instead of one per character on the main thread.
    private func scheduleRefilter() {
        // Every keystroke invalidates whatever search is running or pending, so a
        // late result for the previous query can never land (KEY-02).
        invalidateSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounce?.cancel()
        if trimmed.isEmpty {
            // Immediate: clearing search should never feel laggy.
            searchError = nil
            semanticMatches = [:]
            fusedQuery = nil
            clips = residentClips()
            completedQuery = ""
            return
        }
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            // refilter touches @Published state; route it through the main
            // thread so SwiftUI observes the change on the right queue.
            await MainActor.run { self.refilter() }
        }
    }

    /// True while `clips` still holds results for an older query.
    var hasPendingSearch: Bool {
        completedQuery != query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Skips the debounce: runs the search for the current query now. Used when
    /// the user commits (Return) before the debounce fired.
    func searchNow() {
        guard hasPendingSearch else { return }
        searchDebounce?.cancel()
        refilter()
    }

    /// Bump the generation and cancel the running search. Called on EVERY path
    /// (empty query included) so no earlier completion can overwrite the list.
    private func invalidateSearch() {
        refilterToken &+= 1
        searchTask?.cancel()
        searchTask = nil
        semanticTask?.cancel()
        semanticTask = nil
    }

    private func refilter() {
        invalidateSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchError = nil
            semanticMatches = [:]
            fusedQuery = nil
            clips = residentClips()
            completedQuery = ""
            return
        }
        let token = refilterToken
        let database = self.database
        let limit = displayLimit
        let run = searchRunner
        // A cancellable task keyed by the generation: cancelled before the read
        // starts or before publishing, it does nothing.
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let outcome: Result<[Clip], Error>
            do {
                outcome = .success(try run(database, trimmed, limit))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refilterToken == token else { return }
                switch outcome {
                case .success(let found):
                    self.searchError = nil
                    self.completedQuery = trimmed
                    self.publishKeywordResults(found, query: trimmed, token: token)
                case .failure(let error):
                    ClippyLog.error("Search failed: \(error)", category: ClippyLog.storage)
                    // The banner carries the failure and a Retry action. The list is
                    // emptied because `completedQuery` now names this query: leaving
                    // the previous query's results would let Return paste its top clip.
                    self.searchError = error.localizedDescription
                    self.fusedQuery = nil
                    self.publishResults([], matches: [:])
                    self.completedQuery = trimmed
                }
            }
        }
    }

    /// Shows the keyword hits, then lets the semantic pass fuse them. When the
    /// fused order for this very query is already on screen (a DB pulse refreshing
    /// the search), it stays until the new fused order is ready, so the list does
    /// not flash keyword order or lose the cursor's anchor in between.
    private func publishKeywordResults(_ found: [Clip], query trimmed: String, token: Int) {
        let semantic = SemanticSearchGate.shouldRun(query: trimmed, optedIn: semanticEnvironment.isEnabled())
        if !(semantic && fusedQuery == trimmed) {
            fusedQuery = nil
            publishResults(found, matches: [:])
        }
        if semantic { scheduleSemanticMerge(query: trimmed, token: token, keyword: found) }
    }

    /// Assigns only what changed, so an identical refresh invalidates no view.
    func publishResults(_ newClips: [Clip], matches: [Int64: SearchMatchSource]) {
        if clips != newClips { clips = newClips }
        if semanticMatches != matches { semanticMatches = matches }
    }
}

extension Clip {
    /// In-memory match used to scope the search field to the active category
    /// pane (the database search runs against the whole history). Understands
    /// the same grammar as ClipDatabase.search except `in:` (the pane already
    /// scopes the category), and matches free text the same way: anywhere in
    /// the text, title or OCR text, case- and diacritic-insensitive. The source
    /// app name is not free text in either place (`app:` filters it), so a
    /// result never appears without a visible match.
    func matchesLocally(query: String) -> Bool {
        matchesLocally(ClipQueryParser.parse(query))
    }

    /// Same match for an already parsed query, so a pane filtering many clips
    /// parses once.
    func matchesLocally(_ parsed: ParsedQuery) -> Bool {
        if !parsed.kinds.isEmpty, !parsed.kinds.contains(where: { $0.matches(self) }) { return false }
        if parsed.excludedKinds.contains(where: { $0.matches(self) }) { return false }
        let name = sourceAppName?.lowercased() ?? ""
        let bundle = sourceAppBundleID?.lowercased() ?? ""
        if !parsed.sourceApps.isEmpty,
            !parsed.sourceApps.contains(where: { name.contains($0) || bundle.contains($0) })
        {
            return false
        }
        if parsed.excludedApps.contains(where: { name.contains($0) || bundle.contains($0) }) { return false }
        if let since = parsed.since, createdAt < since { return false }
        if let until = parsed.until, createdAt >= until { return false }
        if !parsed.sizeConstraints.isEmpty {
            let size = byteSize ?? contentText.utf8.count
            if !parsed.sizeConstraints.allSatisfy({ $0.matches(size) }) { return false }
        }

        let haystacks = [contentText, userTitle ?? "", ocrText ?? ""]
        func has(_ needle: String) -> Bool { haystacks.contains { SearchHighlight.contains($0, needle) } }
        if parsed.excludedTerms.contains(where: has) || parsed.excludedPhrases.contains(where: has) { return false }
        return parsed.highlightTerms.allSatisfy(has)
    }
}
