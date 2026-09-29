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
    func sections(for clips: [Clip]) -> [Section] {
        let rows = Array(clips.enumerated()).map { (index: $0.offset, clip: $0.element) }
        // Date headers only make sense for the chronological history.
        guard settings.showSectionHeaders, selection == .history else {
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
        let density = prefs.density
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
                LazyVStack(spacing: density == .compact ? 2 : GridMetrics.spacing, pinnedViews: []) {
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
                guard visibleClips.indices.contains(newIndex) else { return }
                // Keep the anchor id in sync so a DB pulse can re-index onto the
                // same clip instead of jumping to the top.
                anchoredClipID = visibleClips[newIndex].id
                proxy.scrollTo(visibleClips[newIndex].id, anchor: nil)
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
        let isSensitive: Bool
    }

    func cardMetadata(for clips: [Clip]) -> [Int64: CardMetadata] {
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
                pinnedCategory: memberCats.first,
                isSensitive: CardSensitivity.isSensitive(clip)
            )
        }
        return map
    }

    /// Section header: small-caps title with a count badge; no rule line.
    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(PanelTypography.micro(settings).weight(.semibold))
                .foregroundStyle(tokens.textSecondary)
                .kerning(0.6)
            Text("\(count)")
                .font(PanelTypography.micro(settings))
                .foregroundStyle(tokens.textSecondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Observes `GridPreferences` so only the list body re-renders on a density or
/// column change; the parent view does not need to observe it.
struct GridPreferencesReader<Content: View>: View {
    @ObservedObject private var prefs = GridPreferences.shared
    private let content: (GridPreferences) -> Content

    init(@ViewBuilder content: @escaping (GridPreferences) -> Content) {
        self.content = content
    }

    var body: some View { content(prefs) }
}
