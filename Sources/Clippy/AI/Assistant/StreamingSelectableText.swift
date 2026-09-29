import SwiftUI
import AppKit

// MARK: - Conditional text selection

extension View {
    /// Enables text selection only when `enabled` is true. When false the view is
    /// returned unmodified so SwiftUI never installs its SelectionOverlay, keeping
    /// the rapidly-mutating streaming bubble out of the AppKit text-layout path.
    @ViewBuilder
    func textSelectionEnabled(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}

// MARK: - Streaming selectable text

/// A read-only, selectable NSTextView wrapped for SwiftUI. Used for the live
/// streaming AI bubble so its text is selectable WITHOUT SwiftUI's SelectionOverlay,
/// which re-enters the view-graph transaction per token and never converges.
/// AppKit handles selection and lays out once per token, so it stays flat.
struct StreamingSelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // Hug content vertically and let the container set the width so text wraps.
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        if textView.string != text { textView.string = text }
        textView.font = font
        textView.textColor = color
        // One re-measure per token; no SwiftUI selection overlay is involved.
        textView.invalidateIntrinsicContentSize()
    }
}

/// NSTextView that reports its laid-out height as intrinsic content size so SwiftUI
/// can size the bubble to the text. Width is driven by the SwiftUI container.
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }
}
