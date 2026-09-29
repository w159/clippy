import Foundation

/// What Escape does at this moment (PNL-11).
enum EscapeAction: Equatable {
    /// Drop a multi-selection (existing behavior, always first).
    case clearSelection
    /// First press with a query present: clear it.
    case clearQuery
    /// Nothing left to dismiss: hide the panel.
    case hidePanel

    /// Two-stage Escape: selection, then query, then the panel.
    static func next(hasMultiSelection: Bool, query: String) -> EscapeAction {
        if hasMultiSelection { return .clearSelection }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .clearQuery }
        return .hidePanel
    }
}

/// Cmd+1..9 quick paste: maps a digit to the Nth visible clip (FEAT-03).
enum QuickPasteMap {
    /// Zero-based clip index for a typed digit character, nil when not 1-9 or
    /// beyond `visibleCount`.
    static func index(forDigit digit: Character, visibleCount: Int) -> Int? {
        guard let value = digit.wholeNumberValue, (1...9).contains(value), value <= visibleCount else { return nil }
        return value - 1
    }
}

/// Where the main search field is meaningful (KEY-09).
enum SearchFieldPolicy {
    static func showsSearchField(for selection: PanelSelection) -> Bool {
        switch selection {
        case .history, .category, .suggestions: return true
        case .onePassword, .scripts, .assistant, .aiActions, .snippets, .pasteStack: return false
        }
    }
}

/// How a right-click on a card resolves against the current selection (KEY-07).
enum ContextMenuScope: Equatable {
    /// The card is part of a multi-selection: show batch actions.
    case batch
    /// Act on the clicked card alone; the view selects it first.
    case single

    static func resolve(clickedID: Int64?, multiSelection: Set<Int64>) -> ContextMenuScope {
        guard multiSelection.count >= 2, let clickedID, multiSelection.contains(clickedID) else { return .single }
        return .batch
    }
}

/// Which focus target holds keyboard input (KEY-06).
enum PanelFocusTarget: Hashable {
    case search, list
}

/// Decision for Cmd+A (KEY-05): text when the field is being edited, else clips.
enum SelectAllTarget: Equatable {
    case text, clips

    static func resolve(query: String, searchHasFocus: Bool, fieldHasSelection: Bool) -> SelectAllTarget {
        (searchHasFocus && (!query.isEmpty || fieldHasSelection)) ? .text : .clips
    }
}
