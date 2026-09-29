import AppKit
import SwiftUI

/// Transparent strip that lets the user drag the panel window by it (PNL-01).
/// The header embeds it as a `.background`; controls layered above it keep
/// receiving their own clicks because only the empty area falls through here.
struct WindowDragRegion: NSViewRepresentable {
    /// Creates the AppKit view whose mouse-downs move the hosting window.
    func makeNSView(context: Context) -> DragRegionView {
        DragRegionView()
    }

    /// Nothing to update: the view is stateless.
    func updateNSView(_ nsView: DragRegionView, context: Context) {}

    /// NSView that opts in to window dragging through `mouseDownCanMoveWindow`.
    final class DragRegionView: NSView {
        /// Mouse-downs on this view start a window move.
        override var mouseDownCanMoveWindow: Bool { true }

        /// Clicks on the strip never activate the app.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
