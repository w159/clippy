import AppKit
import Foundation

/// Identity of a focusable sidebar row.
enum SidebarRowID: Hashable {
    case history
    case category(Int64)
    case onePassword
    case scripts
    case suggestions
    case assistant
    case aiActions
    case snippets
    case pasteStack
    case newCategory
}

/// Pure keyboard-navigation helper for the ordered sidebar rows.
enum SidebarNavigation {
    /// The row `delta` steps from `current`, clamped to the ends; the first row when nothing is focused.
    static func step(in rows: [SidebarRowID], from current: SidebarRowID?, delta: Int) -> SidebarRowID? {
        guard !rows.isEmpty else { return nil }
        guard let current, let index = rows.firstIndex(of: current) else { return rows.first }
        return rows[min(max(index + delta, 0), rows.count - 1)]
    }
}

/// Tracks whether the drag in flight is a category row, so hover indicators can
/// tell reordering from clip filing (SBR-05). SwiftUI's `isTargeted` does not
/// expose the payload, so category rows report drag start through `.onDrag`.
final class SidebarDragState: ObservableObject {
    /// Category currently being dragged from this pane, if any.
    @Published private(set) var draggingCategoryID: Int64?
    private var watchdog: Timer?

    /// Drag token for a category row; matches `routeCategoryRowDrop`.
    static func token(forCategory id: Int64) -> String { "reorder:cat:\(id)" }

    /// Marks a category drag as started. Clears itself once the mouse is released (covers cancelled drags).
    func begin(_ categoryID: Int64) {
        draggingCategoryID = categoryID
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.end() }
        }
    }

    /// Clears the drag marker.
    func end() {
        watchdog?.invalidate()
        watchdog = nil
        draggingCategoryID = nil
    }

    deinit { watchdog?.invalidate() }
}
