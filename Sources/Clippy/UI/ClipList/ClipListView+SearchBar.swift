import SwiftUI
import AppKit

// Header search area for `ClipListView`: the search field with placeholder and
// grammar hint, the inline query-warning notice and the filter chips row.

extension ClipListView {
    // MARK: - Header

    /// The search field with the panel-focus wiring, shown in the merged header row.
    var headerSearchField: some View {
        searchField
            .onAppear { focusTarget = .search }
            // PNL-04: an already-visible panel focuses the field instead of rebuilding.
            .onChange(of: PanelFocusRequest.shared.token) { _, _ in focusTarget = .search }
            .onChange(of: PanelFocusRequest.shared.listToken) { _, _ in focusList() }
    }

    /// True when the warning notice or the chip row needs space under the header.
    var showsSearchExtras: Bool { !searchWarnings.isEmpty || showsFilterRow }

    /// Warning notice and filter chips stacked under the header.
    var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !searchWarnings.isEmpty { searchNotice }
            if showsFilterRow {
                SearchChipsRow(query: $store.query, categories: store.categories, appNames: knownAppNames)
                    .frame(height: 28)
                    .transition(.opacity)
            }
        }
        .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: showsFilterRow)
        .padding(.horizontal, designTokens.metrics.space.four)
        .padding(.bottom, designTokens.metrics.space.two)
    }

    /// The text field with a search glyph, grammar help and a clear button.
    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Explicit prompt color: the system placeholder follows the window
            // appearance, not the theme, and vanishes when the two disagree.
            TextField(text: $store.query, selection: $searchSelection,
                      prompt: Text("Search clips").foregroundStyle(.secondary)) {
                Text("Search clips")
            }
                .textFieldStyle(.plain)
                .font(.title3)
                .foregroundStyle(.primary)
                .focused($focusTarget, equals: .search)
                .accessibilityLabel("Search clips")
                .accessibilityHint("Supports quotes, minus to exclude, and kind, app, in, before, after, on and size filters.")
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleKey(press, from: .search)
                }
            if PanelDisclosure.showsOperatorHints(focused: focusTarget == .search, query: store.query) {
                Text("kind:  app:  in:  before:  after:")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .accessibilityHidden(true)
            } else if !store.query.isEmpty {
                IconButton("xmark.circle.fill", label: "Clear search", help: "Clear search") { store.query = "" }
            }
            IconButton("line.3.horizontal.decrease.circle", label: "Filters",
                       help: "Show or hide filters. " + SearchWarnings.grammarHint,
                       state: showsFilterRow ? .selected : .rest) { filtersExpanded.toggle() }
                .accessibilityValue(showsFilterRow ? "shown" : "hidden")
        }
        .help(SearchWarnings.grammarHint)
    }

    /// Whether the chip row is visible (searching, filtering or opened by the user).
    var showsFilterRow: Bool {
        let editor = SearchChipEditor(
            categoryID: { name in store.categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id },
            categoryName: { id in store.categories.first { $0.id == id }?.name },
            appNames: []
        )
        return PanelDisclosure.showsFilterRow(query: store.query, hasActiveFilters: !editor.filter(of: store.query).isEmpty,
                                              userToggled: filtersExpanded)
    }

    /// Dismissible inline notice listing parser warnings for the current query.
    var searchNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: BannerSeverity.warning.symbol)
                .foregroundStyle(designTokens.warning)
                .accessibilityHidden(true)
            Text(searchWarnings.joined(separator: ". "))
                .font(.caption)
                .foregroundStyle(tokens.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            IconButton("xmark", label: "Dismiss search notice", help: "Dismiss") { dismissedWarningQuery = store.query }
        }
        .accessibilityElement(children: .contain)
    }

    /// Parser warnings for the current query, empty once the user dismissed them
    /// for that exact query text.
    var searchWarnings: [String] {
        guard dismissedWarningQuery != store.query else { return [] }
        return SearchWarnings.messages(for: store.query)
    }

    /// Distinct source-app names in loaded clips, for the app filter chip.
    var knownAppNames: [String] {
        Array(Set(store.clips.compactMap(\.sourceAppName))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
