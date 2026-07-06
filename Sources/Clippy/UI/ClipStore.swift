import Foundation
import Combine
import GRDB
#if canImport(AppKit)
import AppKit
#endif

/// View model for the panel: live observation of clips, categories, and
/// membership; FTS5 search when a query is typed. "Pinned" is derived:
/// a clip is pinned when it belongs to at least one category.
final class ClipStore: ObservableObject {
    @Published var query: String = "" {
        didSet { scheduleRefilter() }
    }
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var membership: [Int64: Set<Int64>] = [:]
    /// Per-category ordered clip ID lists, keyed by categoryID.
    /// Reflects clip_category.sortOrder so category panes can present clips
    /// in user-defined order rather than global createdAt order.
    @Published private(set) var categoryClipOrder: [Int64: [Int64]] = [:]
    /// Last search failure. Non-nil triggers an error banner with Retry in the
    /// panel. Cleared on the next successful search or when the query empties.
    @Published var searchError: String?
    /// Last DB observation failure. Non-nil triggers an error banner with a
    /// Retry that re-starts the ValueObservation pipelines.
    @Published var observationError: String?

    private var recents: [Clip] = [] {
        didSet {
            // Rebuilt once per observation pulse instead of once per
            // clipsForCategory call: the id lookup is hit several times per
            // redraw (sections, metadata, keyboard handling all query it).
            recentsByID = Dictionary(uniqueKeysWithValues: recents.compactMap { clip in
                clip.id.map { ($0, clip) }
            })
            refilter()
        }
    }
    /// id -> clip lookup over `recents`, kept in sync by `recents.didSet`.
    private var recentsByID: [Int64: Clip] = [:]
    private var searchDebounce: Task<Void, Never>?
    /// Monotonic generation for the async FTS search. Incremented on every
    /// refilter that kicks off a background read; the completion discards
    /// results from any earlier generation so a fast-typed query or a DB pulse
    /// mid-search cannot overwrite the current results with stale ones.
    private var refilterToken = 0
    private var clipsCancellable: AnyDatabaseCancellable?
    private var categoriesCancellable: AnyDatabaseCancellable?
    private let database: ClipDatabase
    private let displayLimit = 300
    /// Serial lane for mutation writes. The shared DatabaseQueue serializes all
    /// access, so a synchronous write from the main thread stalls the UI while
    /// a capture write or iCloud export holds the queue (reads already moved
    /// off-main in refilter). One serial queue, not .global, so rapid mutations
    /// such as successive drag-reorders apply in the order they were issued.
    /// The GRDB ValueObservation republishes state after each write, so the UI
    /// never needs to wait on the write itself.
    private let writeQueue = DispatchQueue(label: "com.clippy.ClipStore.writes", qos: .userInitiated)

    init(database: ClipDatabase) {
        self.database = database
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
        // stay visible in their panes even when older than the window.
        let clipObservation = ValueObservation.tracking { db in
            try Clip.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE id IN (SELECT clipID FROM clip_category)
                    OR id IN (SELECT id FROM clips ORDER BY createdAt DESC, id DESC LIMIT ?)
                    ORDER BY createdAt DESC, id DESC
                    """,
                arguments: [limit]
            )
        }
        // .immediate delivers the first batch synchronously before start() returns,
        // so the panel always has data the moment it becomes visible. Subsequent
        // updates still arrive asynchronously (GRDB coalesces them).
        clipsCancellable = clipObservation.start(
            in: database.dbQueue,
            scheduling: .immediate,
            onError: { [weak self] error in
                ClippyLog.error("Clip observation failed: \(error)", category: ClippyLog.storage)
                DispatchQueue.main.async { self?.observationError = error.localizedDescription }
            },
            onChange: { [weak self] clips in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.observationError = nil
                    self.recents = clips
                }
            }
        )

        let categoryObservation = ValueObservation.tracking { db -> ([Category], [Int64: Set<Int64>], [Int64: [Int64]]) in
            let categories = try Category.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
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
                ClippyLog.error("Category observation failed: \(error)", category: ClippyLog.storage)
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
            ClippyLog.info("trimResident: reduced resident clips to \(trimLimit)",
                           category: ClippyLog.storage)
        }
    }

    // MARK: - Derived data

    /// Distinct source apps seen in history, for category icon pickers.
    var knownBundleIDs: [String] {
        var seen = Set<String>()
        return clips.compactMap(\.sourceAppBundleID).filter { seen.insert($0).inserted }
    }

    // MARK: - Membership queries

    func isPinned(_ clip: Clip) -> Bool {
        guard let id = clip.id else { return false }
        return !(membership[id] ?? []).isEmpty
    }

    func categoryIDs(for clip: Clip) -> Set<Int64> {
        guard let id = clip.id else { return [] }
        return membership[id] ?? []
    }

    func clipCount(inCategory categoryID: Int64) -> Int {
        membership.values.reduce(0) { $0 + ($1.contains(categoryID) ? 1 : 0) }
    }

    // MARK: - Actions

    /// Enqueue a DB mutation on the serial write lane. Failures were previously
    /// swallowed with try?; log them so background writes are not silent.
    private func performWrite(_ label: String, _ body: @escaping () throws -> Void) {
        writeQueue.async {
            do {
                try body()
            } catch {
                ClippyLog.error("\(label) failed: \(error)", category: ClippyLog.storage)
            }
        }
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
        let others = AppSettings.shared.allowMultipleCategories
            ? []
            : (membership[clipID] ?? []).subtracting([categoryID])
        performWrite("fileClip") { [database] in
            // Mirror the removal path used by setClip(... false): clear the clip
            // from each other category before adding it to the target.
            for existing in others {
                try database.setClip(clipID, inCategory: existing, false)
            }
            try database.setClip(clipID, inCategory: categoryID, true)
        }
    }

    @discardableResult
    func createCategory(named name: String, colorHex: String, iconKind: CategoryIconKind, iconValue: String) -> Category? {
        try? database.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
    }

    func updateCategory(_ category: Category) {
        try? database.updateCategory(category)
    }

    func deleteCategory(_ category: Category) {
        guard let id = category.id else { return }
        try? database.deleteCategory(id: id)
    }

    /// Move one category so it sits just before another (drag-to-reorder).
    func moveCategory(id: Int64, beforeCategoryID: Int64) {
        performWrite("moveCategory") { [database] in
            try database.moveCategory(id: id, before: beforeCategoryID)
        }
    }

    /// Clips for a category in user-defined sortOrder. Uses the categoryClipOrder
    /// map so the result is instantly consistent with the live observation.
    /// When a search query is active, the result is further filtered in-memory
    /// so the search bar scopes to the pane the user is viewing.
    func clipsForCategory(_ categoryID: Int64) -> [Clip] {
        // Source from `recents` (every categorized clip, unconditionally) rather
        // than `clips` (overwritten by FTS search results): otherwise an active
        // global search query makes category members that do not match the query
        // vanish from their own category pane.
        let ordered: [Clip]
        if let orderedIDs = categoryClipOrder[categoryID] {
            ordered = orderedIDs.compactMap { recentsByID[$0] }
        } else {
            ordered = recents.filter { membership[$0.id ?? -1]?.contains(categoryID) == true }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { $0.matchesLocally(query: trimmed) }
    }

    /// Move a clip to a new position within a category (drag-to-reorder).
    /// `targetClipID` is the clip the dragged one is dropped onto; pass nil to
    /// move to the end of the list.
    func moveClip(_ clipID: Int64, inCategory categoryID: Int64, before targetClipID: Int64?) {
        // Optimistic: republish the reordered ids immediately so the drop
        // animates without waiting on the DB write. The observation pulse that
        // follows the write recomputes the identical order (same reorderIDs
        // applied to the same list), so no visible correction occurs.
        if let current = categoryClipOrder[categoryID], current.contains(clipID) {
            categoryClipOrder[categoryID] = reorderIDs(current, draggedID: clipID, before: targetClipID)
        }
        performWrite("moveClip") { [database] in
            try database.moveClip(clipID, inCategory: categoryID, before: targetClipID)
        }
    }

    func delete(_ clip: Clip) {
        guard let id = clip.id else { return }
        performWrite("deleteClip") { [database] in
            try database.deleteClip(id: id)
        }
    }

    /// Save edited clip text. Returns true on success so the editor can keep
    /// its window open and surface the failure instead of silently discarding.
    @discardableResult
    func updateText(of clip: Clip, to newText: String) -> Bool {
        guard let id = clip.id else { return false }
        do {
            try database.updateClipText(id: id, newText: newText)
            return true
        } catch {
            ClippyLog.error("failed to update clip text: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// Save an edited image clip: store the new PNG, repoint the row, free the
    /// old files. Returns true on success so the editor can confirm.
    @discardableResult
    func updateImage(of clip: Clip, to pngData: Data) -> Bool {
        guard let id = clip.id else { return false }
        do {
            let stored = try database.media.store(pngData: pngData)
            try database.updateClipImage(id: id, stored: stored)
            return true
        } catch {
            ClippyLog.error("failed to save edited image: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// The on-disk URL of an image clip's full-resolution PNG, for the editor.
    func imageURL(for clip: Clip) -> URL? {
        clip.mediaFilename.map { database.media.url(for: $0) }
    }

    /// Save script stdout as a new clip in history. Distinct from the capture
    /// pipeline: no deduplication, source set to "Clippy Scripts".
    @discardableResult
    func saveScriptOutput(_ text: String) -> Bool {
        do {
            try database.insertTextClip(text)
            return true
        } catch {
            ClippyLog.error("failed to save script output: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// Run OCR on an image clip, copy the result to the clipboard, and save it
    /// as a new text clip. The `completion` block is always called on the main
    /// queue and carries a human-readable outcome message for display.
    func extractText(from clip: Clip, completion: @escaping (String) -> Void) {
        guard clip.contentKind == .image,
              let filename = clip.mediaFilename else {
            completion("No image data for this clip.")
            return
        }
        let imageURL = database.media.url(for: filename)
        OCRService.recognizeText(in: imageURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text) where text.isEmpty:
                completion("No text found in image.")
            case .success(let text):
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
                do {
                    try self.database.insertTextClip(text, sourceAppName: "Clippy OCR")
                    completion("Text extracted and copied to clipboard.")
                } catch {
                    ClippyLog.error("OCR insert failed: \(error)", category: ClippyLog.storage)
                    // Clipboard copy succeeded even if the save did not.
                    completion("Text copied to clipboard (save failed).")
                }
            case .failure(let error):
                ClippyLog.error("OCR recognition failed: \(error)", category: ClippyLog.storage)
                completion("Text extraction failed: \(error.localizedDescription)")
            }
        }
    }

    /// Set or clear a clip's custom title. Returns true on success so the
    /// editor can keep its window open and surface the failure.
    @discardableResult
    func renameClip(_ clip: Clip, userTitle: String?) -> Bool {
        guard let id = clip.id else { return false }
        // Treat empty string the same as nil (clear the custom title).
        let trimmed = userTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            try database.updateClipTitle(id: id, userTitle: trimmed?.isEmpty == true ? nil : trimmed)
            return true
        } catch {
            ClippyLog.error("failed to rename clip: \(error)", category: ClippyLog.storage)
            return false
        }
    }

    /// The first category this clip belongs to, ordered by (sortOrder, createdAt).
    /// Used to pick the icon and accent color for pinned cards.
    func firstCategory(for clip: Clip) -> Category? {
        let ids = categoryIDs(for: clip)
        return categories.first { $0.id.map { ids.contains($0) } ?? false }
    }

    /// Debounced entry from `query.didSet`. An empty query refilters
    /// immediately (so clearing search feels instant); a non-empty query waits
    /// ~180ms for the user to stop typing, coalescing rapid keystrokes into one
    /// FTS5 read instead of one per character on the main thread.
    private func scheduleRefilter() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounce?.cancel()
        if trimmed.isEmpty {
            // Immediate: clearing search should never feel laggy.
            searchError = nil
            clips = recents
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

    private func refilter() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchError = nil
            clips = recents
            return
        }
        // Run the FTS read off the main thread. The shared DatabaseQueue
        // serializes access, so a background read no longer blocks the main
        // thread while a capture write or iCloud export holds the queue.
        refilterToken &+= 1
        let token = refilterToken
        let database = self.database
        let limit = displayLimit
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<[Clip], Error>
            do {
                outcome = .success(try database.searchClips(matching: trimmed, limit: limit))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refilterToken == token else { return }
                switch outcome {
                case .success(let found):
                    self.clips = found
                    self.searchError = nil
                case .failure(let error):
                    ClippyLog.error("Search failed: \(error)", category: ClippyLog.storage)
                    // Keep the last results on screen rather than wiping to empty; the
                    // banner carries the failure and a Retry action.
                    self.searchError = error.localizedDescription
                }
            }
        }
    }
}

extension Clip {
    /// In-memory match used to scope the search field to the active category
    /// pane (FTS5 only runs against the global history window). Understands the
    /// same `#`-token grammar as ClipDatabase.searchClips: kind, app, and
    /// duration tokens filter; the remaining free text is a case-insensitive
    /// substring match against text, title, and source app name.
    func matchesLocally(query: String) -> Bool {
        let parsed = ClipQueryParser.parse(query)

        if !parsed.kinds.isEmpty, !parsed.kinds.contains(where: { $0.matches(self) }) {
            return false
        }
        if !parsed.sourceApps.isEmpty {
            let name = sourceAppName?.lowercased() ?? ""
            let bundle = sourceAppBundleID?.lowercased() ?? ""
            guard parsed.sourceApps.contains(where: { name.contains($0) || bundle.contains($0) }) else {
                return false
            }
        }
        if let since = parsed.since, createdAt < since {
            return false
        }

        let needle = parsed.text.lowercased()
        guard !needle.isEmpty else { return true }
        if contentText.lowercased().contains(needle) { return true }
        if let title = userTitle, title.lowercased().contains(needle) { return true }
        if let app = sourceAppName, app.lowercased().contains(needle) { return true }
        return false
    }
}
