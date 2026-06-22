import SwiftUI

// MARK: - Reusable icon picker

/// Symbols / Emoji / Apps tab picker, identical to the one in CategoryEditorView.
/// Bind `iconKind` and `iconValue` and the view manages selection internally,
/// writing back through the bindings on every tap.
///
/// `knownBundleIDs` feeds the Apps tab. Pass an empty array to show the
/// "Copy something from an app..." placeholder.
///
/// `accentHex` tints the selected-cell background the same way CategoryEditorView
/// does; pass nil to fall back to a plain `.accentColor` tint.
struct IconPickerView: View {
    @Binding var iconKind: CategoryIconKind
    @Binding var iconValue: String
    var knownBundleIDs: [String] = []
    /// Optional hex string used to colorize the selected cell background.
    var accentHex: String? = nil

    @State private var iconTab: CategoryIconKind
    @State private var symbolQuery: String = ""
    @State private var emojiQuery: String = ""

    init(
        iconKind: Binding<CategoryIconKind>,
        iconValue: Binding<String>,
        knownBundleIDs: [String] = [],
        accentHex: String? = nil
    ) {
        _iconKind = iconKind
        _iconValue = iconValue
        self.knownBundleIDs = knownBundleIDs
        self.accentHex = accentHex
        // Start the tab on whatever kind is already selected.
        _iconTab = State(initialValue: iconKind.wrappedValue)
    }

    /// Symbols matching the current query (case-insensitive substring on the
    /// symbol name). An empty query shows the full curated list.
    private var filteredSymbols: [String] {
        let query = symbolQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return CategorySymbols.all }
        return CategorySymbols.all.filter { $0.localizedStandardContains(query) }
    }

    private static let emojis: [String] = [
        "\u{1F4CC}", "\u{2B50}", "\u{2764}\u{FE0F}", "\u{1F525}", "\u{26A1}", "\u{1F3F7}",
        "\u{1F4C1}", "\u{1F5C2}", "\u{1F4C4}", "\u{1F4BB}", "\u{1F9E0}", "\u{1F517}",
        "\u{2709}\u{FE0F}", "\u{1F511}", "\u{1F512}", "\u{1F4B3}", "\u{1F6D2}", "\u{1F381}",
        "\u{1F4DA}", "\u{1F393}", "\u{1F4BC}", "\u{1F3E0}", "\u{2708}\u{FE0F}", "\u{1F697}",
        "\u{1F3AE}", "\u{1F3B5}", "\u{1F5BC}", "\u{1F3A8}", "\u{1F4A1}", "\u{2705}",
        "\u{1F4DD}", "\u{1F916}",
    ]

    // Searchable names for the emoji tab, parallel to `emojis`. SF Symbols have
    // names the system can match; emojis do not, so we carry a small keyword per
    // emoji to power the filter field below.
    private static let emojiNames: [String] = [
        "pushpin", "star", "heart", "fire", "bolt", "label",
        "folder", "folder open", "document", "laptop", "brain", "link",
        "envelope", "key", "lock", "card", "cart", "gift",
        "books", "graduation", "briefcase", "house", "plane", "car",
        "game", "music", "picture", "art", "idea", "check",
        "memo", "robot",
    ]

    /// Emojis whose keyword matches the emoji-tab query. An empty query shows the
    /// full curated list, mirroring how the symbols tab behaves.
    private var filteredEmojis: [(emoji: String, name: String)] {
        let q = emojiQuery.trimmingCharacters(in: .whitespaces)
        let pairs = zip(Self.emojis, Self.emojiNames).map { (emoji: $0.0, name: $0.1) }
        guard !q.isEmpty else { return pairs }
        return pairs.filter { $0.name.localizedStandardContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Icon", selection: $iconTab) {
                Text("Symbols").tag(CategoryIconKind.symbol)
                Text("Emoji").tag(CategoryIconKind.emoji)
                Text("Apps").tag(CategoryIconKind.appLogo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if iconTab == .symbol {
                TextField("Search symbols", text: $symbolQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            } else if iconTab == .emoji {
                // The emoji tab previously had no search while symbols did. Emojis
                // lack system names, so we match against the keyword list above.
                TextField("Search emoji", text: $emojiQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            iconGrid
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var iconGrid: some View {
        if iconTab == .symbol && filteredSymbols.isEmpty {
            Text("No symbols match")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110)
        } else if iconTab == .emoji && filteredEmojis.isEmpty {
            Text("No emoji match")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110)
        } else {
            symbolEmojiAppGrid
        }
    }

    @ViewBuilder
    private var symbolEmojiAppGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 30), spacing: 4)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                switch iconTab {
                case .symbol:
                    ForEach(filteredSymbols, id: \.self) { symbol in
                        iconCell(isSelected: iconKind == .symbol && iconValue == symbol) {
                            iconKind = .symbol
                            iconValue = symbol
                        } content: {
                            Image(systemName: symbol).font(.system(size: 14))
                        }
                        .accessibilityLabel(symbol)
                    }
                case .emoji:
                    ForEach(filteredEmojis, id: \.emoji) { pair in
                        let emoji = pair.emoji
                        iconCell(isSelected: iconKind == .emoji && iconValue == emoji) {
                            iconKind = .emoji
                            iconValue = emoji
                        } content: {
                            Text(emoji).font(.system(size: 15))
                        }
                        .accessibilityLabel(pair.name)
                    }
                case .appLogo:
                    if knownBundleIDs.isEmpty {
                        Text("Copy something from an app to see its icon here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(3)
                    } else {
                        ForEach(knownBundleIDs, id: \.self) { bundleID in
                            iconCell(isSelected: iconKind == .appLogo && iconValue == bundleID) {
                                iconKind = .appLogo
                                iconValue = bundleID
                            } content: {
                                if let icon = AppIconProvider.shared.icon(forBundleID: bundleID) {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "app.dashed").font(.system(size: 14))
                                }
                            }
                            .accessibilityLabel(bundleID)
                        }
                    }
                }
            }
        }
        .frame(height: 110)
    }

    private func iconCell<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 30, height: 28)
                .background(
                    selectedBackground(isSelected: isSelected),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    private func selectedBackground(isSelected: Bool) -> AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(.clear) }
        if let hex = accentHex {
            return AnyShapeStyle(Color(hexString: hex).opacity(0.25))
        }
        return AnyShapeStyle(Color.accentColor.opacity(0.25))
    }
}

// MARK: - Action icon renderer

/// Renders an AIAction's icon correctly for whichever kind it is.
/// symbol -> SF Symbol image, emoji -> Text, appLogo -> app icon image.
struct ActionIconView: View {
    let kind: CategoryIconKind
    let value: String
    var size: CGFloat = 13

    var body: some View {
        switch kind {
        case .symbol:
            Image(systemName: value.isEmpty ? "wand.and.sparkles" : value)
                .font(.system(size: size))
        case .emoji:
            Text(value)
                .font(.system(size: size + 2))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: value) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size + 3, height: size + 3)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size))
            }
        }
    }
}
