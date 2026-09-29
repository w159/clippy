import SwiftUI

/// Filter chip row under the search field. Chips read and write the query
/// string through `SearchChipEditor`, so the field stays the source of truth.
struct SearchChipsRow: View {
    @Environment(\.clippyTokens) private var tokens
    @Binding var query: String
    let categories: [Category]
    let appNames: [String]

    private var editor: SearchChipEditor {
        SearchChipEditor(
            categoryID: { name in categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id },
            categoryName: { id in categories.first { $0.id == id }?.name },
            appNames: appNames
        )
    }

    private var filter: SearchFilter { editor.filter(of: query) }

    private static let kindChips: [(ClipKindToken, String, String)] = [
        (.text, "Text", "text.alignleft"), (.link, "Links", "link"), (.image, "Images", "photo"),
        (.file, "Files", "doc"), (.color, "Colors", "paintpalette")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassCluster(spacing: tokens.metrics.space.one) {
                HStack(spacing: tokens.metrics.space.one) {
                    FilterChip(model: FilterChipModel(id: "all", title: "All", accessibilityValue: "Show every clip"),
                               state: filter.isEmpty ? .selected : .rest) {
                        query = editor.clearingFilters(in: query)
                    }
                    ForEach(Self.kindChips, id: \.0) { token, title, symbol in
                        FilterChip(model: FilterChipModel(id: token.rawValue, title: title, systemImage: symbol),
                                   state: filter.kinds.contains(token) ? .selected : .rest) {
                            query = editor.toggling(kind: token, in: query)
                        }
                    }
                    dateMenu
                    if !appNames.isEmpty { appMenu }
                    if !categories.isEmpty { categoryMenu }
                    if !filter.isEmpty {
                        FilterChip(model: FilterChipModel(id: "clear", title: "Clear filters", systemImage: "xmark.circle",
                                                          accessibilityValue: "Remove all filter chips")) {
                            query = editor.clearingFilters(in: query)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search filters")
    }

    private var datePreset: SearchDatePreset? {
        SearchDatePreset.matching(filter, now: Date(), calendar: .current)
    }

    private var dateMenu: some View {
        let active = filter.after != nil || filter.before != nil
        return menuChip(title: datePreset?.title ?? (active ? "Custom dates" : "Date"), symbol: "calendar", active: active) {
            ForEach(SearchDatePreset.allCases) { preset in
                Button {
                    query = editor.setting(date: preset, in: query)
                } label: {
                    if datePreset == preset { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                }
            }
            if active {
                Divider()
                Button("Any date") { query = editor.setting(date: nil, in: query) }
            }
        }
    }

    private var appMenu: some View {
        let selected = filter.apps
        return menuChip(title: selected.first ?? "App", symbol: "app", active: !selected.isEmpty, count: selected.count > 1 ? selected.count : nil) {
            ForEach(appNames, id: \.self) { name in
                Button {
                    query = editor.toggling(app: name, in: query)
                } label: {
                    if selected.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        }
    }

    private var categoryMenu: some View {
        let selected = filter.categoryIDs
        let first = categories.first { $0.id == selected.first }?.name
        return menuChip(title: first ?? "Category", symbol: "folder", active: !selected.isEmpty, count: selected.count > 1 ? selected.count : nil) {
            ForEach(categories) { category in
                if let id = category.id {
                    Button {
                        query = editor.toggling(categoryID: id, in: query)
                    } label: {
                        if selected.contains(id) { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
                    }
                }
            }
        }
    }

    private func menuChip<Items: View>(title: String, symbol: String, active: Bool, count: Int? = nil,
                                       @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: tokens.metrics.space.one) {
                Image(systemName: symbol).imageScale(.small)
                Text(title).lineLimit(1)
                if let count { Text("\(count)").font(.caption2.monospacedDigit()) }
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(tokens.textSecondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tokens.textPrimary)
            .padding(.horizontal, tokens.metrics.space.three)
            .padding(.vertical, tokens.metrics.space.one)
            .background(active ? tokens.selection : tokens.surfaceElevated.opacity(0.72), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? tokens.accentText : tokens.stroke, lineWidth: active ? 1.5 : 0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(active ? "Active" : "Off")
    }
}
