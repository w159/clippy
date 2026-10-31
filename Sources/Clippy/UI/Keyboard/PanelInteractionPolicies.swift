import Foundation

// Pure decisions behind the panel's keyboard, focus and selection behaviour.
// They live apart from `ClipListView` so each rule is unit-testable without a
// window server.

/// Which clips an action (Return, Cmd+Delete, Cmd+P, Cmd+C) targets.
///
/// An explicit selection wins over the keyboard cursor. After a Cmd-click that
/// deselected the cursor row, the one remaining selected clip is highlighted
/// while the cursor sits on the deselected row; acting on the cursor then
/// pasted or deleted a clip that looked unselected, while Cmd+C copied the
/// highlighted one.
enum ActionTargetPolicy {
    static func ids(selected: Set<Int64>, cursorID: Int64?, order: [Int64]) -> [Int64] {
        if selected.isEmpty { return cursorID.map { [$0] } ?? [] }
        return order.filter(selected.contains)
    }
}

/// Whether Cmd+Delete removes clips or edits the search text.
enum CommandDeletePolicy {
    /// In the search field with text, Cmd+Backspace is the text-editing
    /// "delete to line start"; deleting a clip there lost the clip and left
    /// Cmd+Z undoing the wrong thing.
    static func deletesClips(source: PanelFocusTarget, query: String) -> Bool {
        !(source == .search && !query.isEmpty)
    }
}

/// The context menu's paste entries follow "paste as plain text by default":
/// the main entry does what Return does, and the second entry is the opposite
/// mode. The menu used to hard-code formatted paste for the main entry.
enum PasteMenuPolicy {
    static func items(defaultPlain: Bool) -> (primaryPlain: Bool, alternate: (title: String, plain: Bool)) {
        defaultPlain
            ? (true, ("Paste with Formatting", false))
            : (false, ("Paste as Plain Text", true))
    }
}

/// Bare digits: a quick-paste shortcut on the Suggestions list, but plain text
/// in the search field, where the user is typing a query.
enum SuggestionDigitPolicy {
    static func pastesSuggestion(selection: PanelSelection, source: PanelFocusTarget, query: String) -> Bool {
        selection == .suggestions && source == .list && query.isEmpty
    }
}

/// Suggestions is a fixed ranked list, not searchable. A query typed while it
/// is open searches History instead of being ignored (Return used to paste the
/// top suggestion, not the top match).
enum SuggestionsQueryPolicy {
    static func redirectsToHistory(selection: PanelSelection, query: String) -> Bool {
        selection == .suggestions && HistoryPanePolicy.isSearching(query)
    }
}

/// Where keyboard focus goes after the view structure changes under it.
enum PanelFocusPolicy {
    /// An inline rename ends: the title field took AppKit first responder outside
    /// SwiftUI focus, so nothing restored `focusTarget`.
    static func afterRenameEnded() -> PanelFocusTarget { .list }

    /// The pane changed. `previous` is where focus was; nil means something
    /// else (the sidebar) owned it and must keep it.
    static func afterPaneChange(previous: PanelFocusTarget?, showsSearchField: Bool, hasClips: Bool) -> PanelFocusTarget? {
        guard let previous, showsSearchField else { return nil }
        if previous == .search { return .search }
        return hasClips ? .list : .search
    }

    /// The visible list became empty (last clip deleted or unfiled). Its
    /// focusable container is gone, so a list-focused panel falls back to the
    /// search field, where typing and Escape still work.
    static func afterListEmptied(previous: PanelFocusTarget?, showsSearchField: Bool) -> PanelFocusTarget? {
        previous == .list && showsSearchField ? .search : nil
    }
}

/// Cmd+K: a second press closes the palette and hands focus back (a bare
/// visibility toggle left nothing focused).
enum PaletteTogglePolicy {
    static func next(isVisible: Bool) -> (visible: Bool, focus: PanelFocusTarget?) {
        isVisible ? (false, .search) : (true, nil)
    }
}

/// "Show in Timeline" clears the query to reach the clip. The query handler
/// that resets the cursor to row 0 must not run for that clear, or it undoes
/// the reveal. Armed only when the query is non-empty, because an empty query
/// produces no change event to consume it.
struct RevealQueryGuard: Equatable {
    private(set) var armed = false

    mutating func arm(currentQuery: String) {
        armed = !currentQuery.isEmpty
    }

    /// True when this query change belongs to a reveal and must not reset the cursor.
    mutating func consumeQueryChange() -> Bool {
        defer { armed = false }
        return armed
    }
}

/// Date section grouping and the keyboard order must agree. While searching,
/// results come word-start tier first, then fragments, each newest first; a
/// date header then repeated (Today, Yesterday, Today). The date-first order
/// keeps one section per day, so Up/Down walk the screen top to bottom. The
/// match tier keeps its place within each day.
enum SearchSectionOrder {
    /// Reorders `items` so equal buckets are adjacent, newest bucket first
    /// (by its newest member), keeping the incoming order within a bucket.
    static func groupedByBucket<T>(_ items: [T], bucket: (T) -> String, date: (T) -> Date) -> [T] {
        var order: [String] = []
        var groups: [String: [T]] = [:]
        var newest: [String: Date] = [:]
        for item in items {
            let key = bucket(item)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
            newest[key] = max(newest[key] ?? .distantPast, date(item))
        }
        let sorted = order.enumerated().sorted { lhs, rhs in
            let l = newest[lhs.element] ?? .distantPast, r = newest[rhs.element] ?? .distantPast
            return l != r ? l > r : lhs.offset < rhs.offset
        }
        return sorted.flatMap { groups[$0.element] ?? [] }
    }
}

/// Outcome of committing a category rename. A duplicate name keeps the field
/// open with an error when the user pressed Return, but if the field lost focus
/// there is nothing left to correct in: the rename is cancelled and the name
/// restored, otherwise the sidebar stays in rename mode and ignores its keys.
enum CategoryRenameOutcome: Equatable {
    case cancel
    case rejectDuplicate
    case save(String)

    static func resolve(draft: String, original: String, isDuplicate: Bool, focusLost: Bool) -> CategoryRenameOutcome {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == original { return .cancel }
        if isDuplicate { return focusLost ? .cancel : .rejectDuplicate }
        return .save(name)
    }
}
