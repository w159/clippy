import Foundation

/// One visible block of palette rows. `title` is nil for the flat search-result list.
struct PaletteGroup {
    let title: String?
    let commands: [any PaletteCommand]
    /// Index of the first row of this group in the flattened list.
    let startIndex: Int
}

/// Pure grouping and section-jump logic for the palette (Mobbin ref 06 section 1).
struct PaletteLayout {
    static let recentTitle = "Recent"

    let groups: [PaletteGroup]

    /// Every row in display order; the highlight index addresses this list.
    var flat: [any PaletteCommand] { groups.flatMap(\.commands) }
    /// First row index of each section, ascending.
    var sectionStarts: [Int] { groups.map(\.startIndex) }

    /// Empty query: Recent first, then one group per `PaletteSection` (original
    /// order inside a group, recents not repeated). Non-empty query: one
    /// header-less list in ranked order.
    static func build(_ commands: [any PaletteCommand], query: String, recents: [String]) -> PaletteLayout {
        let ranked = PaletteRanker.rank(commands, query: query, recents: recents)
        guard PaletteRanker.normalize(query).isEmpty else {
            return PaletteLayout(groups: ranked.isEmpty ? [] : [PaletteGroup(title: nil, commands: ranked, startIndex: 0)])
        }
        let enabled = commands.filter(\.isEnabled)
        let byID = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let recent = recents.compactMap { id -> (any PaletteCommand)? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        var blocks: [(String, [any PaletteCommand])] = []
        if !recent.isEmpty { blocks.append((recentTitle, recent)) }
        let recentIDs = Set(recent.map(\.id))
        for section in PaletteSection.allCases {
            let members = enabled.filter { $0.section == section && !recentIDs.contains($0.id) }
            if !members.isEmpty { blocks.append((section.rawValue, members)) }
        }
        var start = 0
        let groups = blocks.map { title, members -> PaletteGroup in
            defer { start += members.count }
            return PaletteGroup(title: title, commands: members, startIndex: start)
        }
        return PaletteLayout(groups: groups)
    }

    /// Row to highlight after Tab (`forward`) or Shift-Tab: the start of the next
    /// or previous section, wrapping around. `current` in mid-section jumps back
    /// to that section's start first.
    static func jump(from current: Int, sectionStarts: [Int], forward: Bool) -> Int {
        guard let first = sectionStarts.first, let last = sectionStarts.last else { return current }
        if forward { return sectionStarts.first { $0 > current } ?? first }
        return sectionStarts.last { $0 < current } ?? last
    }

    /// Individual key glyphs for a display shortcut: "\u{21E7}\u{21A9}" -> two caps, "Cmd+P" -> two caps.
    static func keyCaps(for shortcut: String) -> [String] {
        if shortcut.count > 1, shortcut.contains("+") {
            return shortcut.split(separator: "+").map(String.init)
        }
        return shortcut.map(String.init)
    }
}
