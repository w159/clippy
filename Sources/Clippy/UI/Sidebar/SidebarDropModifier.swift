import SwiftUI

/// Drop destination for a sidebar row (expanded or rail). Tracks hover in
/// `hover` so the row can render the matching indicator, and forwards the
/// classified action to `perform`.
struct SidebarDropModifier: ViewModifier {
    let row: SidebarDropRow
    @Binding var hover: SidebarDropRow?
    let perform: (SidebarDropAction) -> Bool

    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { items, _ in
            hover = nil
            return perform(SidebarDropTarget.action(for: items, on: row))
        } isTargeted: { isOver in
            if isOver { hover = row } else if hover == row { hover = nil }
        }
    }
}

extension View {
    /// Makes this view a sidebar drop target for `row`.
    func sidebarDrop(row: SidebarDropRow, hover: Binding<SidebarDropRow?>, perform: @escaping (SidebarDropAction) -> Bool) -> some View {
        modifier(SidebarDropModifier(row: row, hover: hover, perform: perform))
    }
}
