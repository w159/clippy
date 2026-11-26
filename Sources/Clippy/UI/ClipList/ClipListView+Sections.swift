import SwiftUI
import AppKit

// Timeline sectioning for `ClipListView`: date-bucket section grouping,
// section titles, column-count math, per-card metadata precompute and the
// sectioned list itself.

extension ClipListView {
    // MARK: - Sectioned list

    struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [(index: Int, clip: Clip)]
    }

    /// Takes the clip snapshot from `sectionedList` so `visibleClips` (a store
    /// filter/join) is evaluated once per redraw, not once per consumer.
    ///
    /// Memoized per (pane, query, store data version, header setting, day): a cursor move
    /// changes none of them, so Up/Down no longer regroups and re-titles every clip.
    /// `clips` must be this pane's `visibleClips`.
    func sections(for clips: [Clip]) -> [Section] {
        guard isMemoizablePane else { return computeSections(for: clips) }
        let key = SectionsCache.SectionsKey(
            selection: selection, query: store.query, version: store.categoryPaneVersion, count: clips.count,
            headers: settings.showSectionHeaders, day: Calendar.current.startOfDay(for: Date()))
        if let hit = sectionsCache.sections(for: key) { return hit }
        let result = computeSections(for: clips)
        sectionsCache.storeSections(result, for: key)
        return result
    }

    /// History and category panes are the ones whose clips `VisibleClipsCache` memoizes by store version.
    private var isMemoizablePane: Bool {
        switch selection {
        case .history, .category: return features.smartClips == nil
        default: return false
        }
    }

    private func computeSections(for clips: [Clip]) -> [Section] {
        let rows = Array(clips.enumerated()).map { (index: $0.offset, clip: $0.element) }
        // Date headers only make sense for the chronological history.
        // Search results are in relevance order: date headers would repeat.
        guard settings.showSectionHeaders, selection == .history,
            !HistoryPanePolicy.isSearching(store.query)
        else {
            return [Section(id: "all", title: "", rows: rows)]
        }

        var grouped: [(title: String, rows: [(index: Int, clip: Clip)])] = []
        for row in rows {
            let title = sectionTitle(for: row.clip)
            if let last = grouped.indices.last, grouped[last].title == title {
                grouped[last].rows.append(row)
            } else {
                grouped.append((title: title, rows: [row]))
            }
        }
        return grouped.map { Section(id: $0.title, title: $0.title, rows: $0.rows) }
    }

    /// Maps a clip to its date bucket; see `TimelineBucket`.
    func sectionTitle(for clip: Clip) -> String {
        TimelineBucket.title(for: clip.createdAt)
    }

    /// Density and column preferences are observed by `GridPreferencesReader`;
    /// the column count comes from the real width inside a GeometryReader so the
    /// first render is already correct (LAY-04).
    var sectionedList: some View {
        GridPreferencesReader { prefs in
            GeometryReader { geometry in
                sectionedListBody(width: geometry.size.width, prefs: prefs)
            }
        }
    }

    func sectionedListBody(width: CGFloat, prefs: GridPreferences) -> some View {
        let columns = GridMetrics.columnCount(forWidth: width, preferred: prefs.columnMode, density: prefs.density)
        let gridItems = Array(repeating: GridItem(.flexible(), spacing: GridMetrics.spacing), count: columns)
        // Snapshot the visible clips once per body evaluation: sections,
        // metadata, the trailing-drop guard, and the footer all previously
        // re-ran the visibleClips filter/join within a single redraw.
        let clips = visibleClips
        // Precompute per-clip membership/pinned/category lookups once per redraw
        // and pass into each card, instead of re-running store.isPinned /
        // store.categories.filter / store.firstCategory per card per body
        // (audit: per-card store membership queries re-run every redraw).
        let metadata = cardMetadata(for: clips)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: GridMetrics.rowSpacing, pinnedViews: []) {
                    Color.clear.frame(height: 0).id(Self.topAnchorID)
                    ForEach(sections(for: clips)) { section in
                        if !section.title.isEmpty {
                            sectionHeader(section.title, count: section.rows.count)
                        }
                        if columns > 1 {
                            LazyVGrid(columns: gridItems, alignment: .leading, spacing: GridMetrics.spacing) {
                                ForEach(section.rows, id: \.clip.id) { row in
                                    card(for: row.clip, at: row.index, metadata: metadata)
                                }
                            }
                        } else {
                            ForEach(section.rows, id: \.clip.id) { row in
                                card(for: row.clip, at: row.index, metadata: metadata)
                            }
                        }
                    }
                    // Audit finding: drag-to-reorder could not drop a clip past
                    // the last clip in a category pane (the per-row destination
                    // only inserts before a target). This trailing target lands
                    // drops past the end and appends via moveClip(before: nil).
                    // History pane has no within-list reorder, so it is excluded.
                    if let categoryID = activeCategoryID, !clips.isEmpty {
                        trailingClipDropZone(inCategory: categoryID)
                    }
                    // Surface the history cap so the user knows older clips are
                    // being truncated (audit: history hard-capped at 300 with no
                    // indication).
                    if selection == .history, store.clips.count >= Self.displayLimit {
                        Text("Showing \(clips.count) most recent")
                            .font(PanelTypography.micro(settings))
                            .foregroundStyle(tokens.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(GridMetrics.listPadding)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                listWidth = width
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                listHeight = height
            }
            // KEY-01: every query, filter or pane change resets to the top so a
            // filtered list can never appear blank behind a stale scroll offset.
            .onChange(of: store.query) { _, _ in proxy.scrollTo(Self.topAnchorID, anchor: .top) }
            .onChange(of: selection) { _, _ in proxy.scrollTo(Self.topAnchorID, anchor: .top) }
            // KEY-06: the list itself takes focus and handles navigation keys.
            .focusable()
            .focusEffectDisabled()
            .focused($focusTarget, equals: .list)
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, from: .list) }
            .onChange(of: selectedIndex) { _, newIndex in
                let current = visibleClips
                guard current.indices.contains(newIndex) else { return }
                // Keep the anchor id in sync so a DB pulse can re-index onto the
                // same clip instead of jumping to the top.
                anchoredClipID = current[newIndex].id
                proxy.scrollTo(current[newIndex].id, anchor: nil)
            }
        }
    }

    /// Column count for the last measured list width; used by keyboard navigation.
    func currentColumnCount() -> Int {
        let prefs = GridPreferences.shared
        return GridMetrics.columnCount(forWidth: listWidth, preferred: prefs.columnMode, density: prefs.density)
    }

    /// Per-clip lookups derived once per redraw so the card builder can do O(1)
    /// lookups instead of re-querying the store for every card.
    struct CardMetadata {
        let isPinned: Bool
        let categoryColors: [Color]
        let pinnedCategory: Category?
    }

    /// Memoized like `sections(for:)`, plus the category list (color or order edits). Sensitivity is
    /// deliberately not part of it: an override can flip without bumping the store version, and
    /// `CardSensitivity.isSensitive` is already cached per clip.
    func cardMetadata(for clips: [Clip]) -> [Int64: CardMetadata] {
        guard isMemoizablePane else { return computeCardMetadata(for: clips) }
        let key = SectionsCache.MetadataKey(
            selection: selection, query: store.query, version: store.categoryPaneVersion, count: clips.count,
            categories: store.categories)
        if let hit = sectionsCache.metadata(for: key) { return hit }
        let result = computeCardMetadata(for: clips)
        sectionsCache.storeMetadata(result, for: key)
        return result
    }

    private func computeCardMetadata(for clips: [Clip]) -> [Int64: CardMetadata] {
        var map: [Int64: CardMetadata] = [:]
        for clip in clips {
            guard let id = clip.id else { continue }
            // One membership lookup per clip. The previous shape re-fetched the
            // Set inside the filter closure (per category, per clip) and then
            // again for isPinned and firstCategory: O(clips x categories) Set
            // copies per redraw.
            let memberIDs = store.categoryIDs(for: clip)
            let memberCats = store.categories.filter { category in
                category.id.map(memberIDs.contains) ?? false
            }
            map[id] = CardMetadata(
                isPinned: !memberIDs.isEmpty,
                categoryColors: memberCats.map { Color(hexString: $0.colorHex) },
                // categories is already (sortOrder, createdAt) ordered, so the
                // first member matches store.firstCategory(for:).
                pinnedCategory: memberCats.first
            )
        }
        return map
    }

    /// Section header: sentence-case title with a quiet count; no rule line.
    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Single-entry memos for `ClipListView.sections(for:)` and `cardMetadata(for:)`. A reference
/// type so filling it during `body` is not a state write (same pattern as `VisibleClipsCache`).
final class SectionsCache {
    struct SectionsKey: Equatable {
        let selection: PanelSelection
        let query: String
        let version: Int
        let count: Int
        let headers: Bool
        let day: Date
    }

    struct MetadataKey: Equatable {
        let selection: PanelSelection
        let query: String
        let version: Int
        let count: Int
        let categories: [Category]
    }

    private var sectionsKey: SectionsKey?
    private var cachedSections: [ClipListView.Section] = []
    private var metadataKey: MetadataKey?
    private var cachedMetadata: [Int64: ClipListView.CardMetadata] = [:]
    /// Test seam: how many times each memo was refilled.
    private(set) var sectionsMissCount = 0
    private(set) var metadataMissCount = 0

    func sections(for key: SectionsKey) -> [ClipListView.Section]? { sectionsKey == key ? cachedSections : nil }

    func storeSections(_ sections: [ClipListView.Section], for key: SectionsKey) {
        sectionsMissCount += 1
        sectionsKey = key
        cachedSections = sections
    }

    func metadata(for key: MetadataKey) -> [Int64: ClipListView.CardMetadata]? { metadataKey == key ? cachedMetadata : nil }

    func storeMetadata(_ metadata: [Int64: ClipListView.CardMetadata], for key: MetadataKey) {
        metadataMissCount += 1
        metadataKey = key
        cachedMetadata = metadata
    }
}

/// Observes `GridPreferences` so only the list body re-renders on a density or
/// column change; the parent view does not need to observe it.
struct GridPreferencesReader<Content: View>: View {
    private let prefs = GridPreferences.shared
    private let content: (GridPreferences) -> Content

    init(@ViewBuilder content: @escaping (GridPreferences) -> Content) {
        self.content = content
    }

    var body: some View { content(prefs) }
}

