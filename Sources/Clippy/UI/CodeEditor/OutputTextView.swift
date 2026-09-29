import AppKit
import SwiftUI

/// Read-only, selectable, monospaced text that scrolls on both axes with a
/// single AppKit scroller pair (no nested SwiftUI scrollers). Used for script
/// output, which can be large and has long lines.
struct OutputTextView: NSViewRepresentable {
    var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var textColor: NSColor = .labelColor
    var background: NSColor = .textBackgroundColor
    /// Keep the view pinned to the end while text streams in.
    var followsTail = false
    var accessibilityLabel: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = []
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = view
        if let accessibilityLabel { view.setAccessibilityLabel(accessibilityLabel) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        scroll.backgroundColor = background
        view.backgroundColor = background
        let coordinator = context.coordinator
        if coordinator.lastText != text || coordinator.lastFont != font || coordinator.lastColor != textColor {
            let atBottom = scroll.verticalScroller.map { $0.doubleValue > 0.98 || scroll.contentView.bounds.height >= view.frame.height } ?? true
            view.textStorage?.setAttributedString(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: textColor]))
            coordinator.lastText = text
            coordinator.lastFont = font
            coordinator.lastColor = textColor
            if followsTail && atBottom { view.scrollToEndOfDocument(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastText: String?
        var lastFont: NSFont?
        var lastColor: NSColor?
    }
}
