import SwiftUI
import AppKit

// Header search area for `ClipListView`: the search field with placeholder and
// grammar hint, the inline query-warning notice and the filter chips row.

extension ClipListView {
    // MARK: - Header

    /// Search field, warning notice and filter chips stacked under the header.
    var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
            if !searchWarnings.isEmpty { searchNotice }
            if showsFilterRow {
                SearchChipsRow(query: $store.query, categories: store.categories, appNames: knownAppNames)
                    .frame(height: 28)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsFilterRow)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
        .onAppear { focusTarget = .search }
        // PNL-04: an already-visible panel focuses the field instead of rebuilding.
        .onReceive(PanelFocusRequest.shared.$token.dropFirst()) { _ in focusTarget = .search }
    }

    /// The text field with a search glyph, grammar help and a clear button.
    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
                .accessibilityHidden(true)
            TextField("Search clips", text: $store.query, selection: $searchSelection)
                .textFieldStyle(.plain)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
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
                .foregroundStyle(Color.orange)
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
