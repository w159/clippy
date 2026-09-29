import Foundation

/// Pure progressive-disclosure rules for the panel chrome: which optional rows
/// appear, which footer hints show, and which sidebar sections start open.
enum PanelDisclosure {
    /// The chip row shows while searching, while any filter is active, or when the user opened it.
    static func showsFilterRow(query: String, hasActiveFilters: Bool, userToggled: Bool) -> Bool {
        userToggled || hasActiveFilters || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Operator hints (`kind: app: ...`) only help an empty, focused field.
    static func showsOperatorHints(focused: Bool, query: String) -> Bool {
        focused && query.isEmpty
    }

    /// One footer hint; `key` is the glyph, `label` the action.
    struct FooterHint: Equatable {
        let key: String
        let label: String
    }

    /// Below this list width the footer trims to three hints.
    static let narrowFooterWidth: CGFloat = 400

    /// Contextual footer hints, at most four (three when narrow).
    static func footerHints(selectedCount: Int, hasClips: Bool, plainByDefault: Bool,
                            isPinnedPanel: Bool, width: CGFloat) -> [FooterHint] {
        var hints: [FooterHint]
        if selectedCount >= 2 {
            hints = [.init(key: "\u{21A9}", label: "paste"), .init(key: "\u{2318}\u{232B}", label: "delete"),
                     .init(key: "\u{2318}K", label: "actions")]
        } else if hasClips {
            hints = [.init(key: "\u{21A9}", label: plainByDefault ? "paste plain" : "paste"),
                     .init(key: "\u{21E7}\u{21A9}", label: plainByDefault ? "formatted" : "plain"),
                     .init(key: "\u{2318}P", label: "pin"),
                     .init(key: "\u{2318}K", label: "actions")]
        } else {
            hints = [.init(key: "\u{2318}K", label: "actions"),
                     .init(key: "\u{238B}", label: isPinnedPanel ? "pinned" : "close")]
        }
        return Array(hints.prefix(width < narrowFooterWidth ? 3 : 4))
    }

    /// Sidebar sections that can collapse.
    enum SidebarSection: String, CaseIterable {
        case library, categories, smartCollections, tools
    }

    /// Sections open on first launch.
    static let defaultExpanded: Set<SidebarSection> = [.library, .categories]

    /// A section always stays open when it holds the current selection.
    static func isExpanded(_ section: SidebarSection, stored: Set<SidebarSection>, containsSelection: Bool) -> Bool {
        containsSelection || stored.contains(section)
    }

    /// Encodes a set for `@AppStorage`.
    static func encode(_ sections: Set<SidebarSection>) -> String {
        sections.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Decodes `@AppStorage`; nil (never stored) yields the defaults, unknown names are dropped.
    static func decode(_ raw: String?) -> Set<SidebarSection> {
        guard let raw else { return defaultExpanded }
        return Set(raw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) })
    }
}
