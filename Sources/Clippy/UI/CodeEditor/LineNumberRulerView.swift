import AppKit

/// Vertical ruler that draws one number per logical line (wrapped continuation
/// lines are not numbered). Line starts come from a cached `LineIndex`.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var index = LineIndex(text: "")
    var gutterFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { updateThickness() } }
    var textColor: NSColor = .secondaryLabelColor
    var backgroundColor: NSColor = .windowBackgroundColor

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged),
                                               name: NSText.didChangeNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        reload()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Rebuilds the line index from the text view's current string.
    func reload() {
        index = LineIndex(text: textView?.string ?? "")
        updateThickness()
        needsDisplay = true
    }

    @objc private func contentChanged() { reload() }
    @objc private func redraw() { needsDisplay = true }

    private func updateThickness() {
        let digits = max(2, String(index.lineCount).count)
        let width = ("8" as NSString).size(withAttributes: [.font: gutterFont]).width
        ruleThickness = ceil(width * CGFloat(digits)) + 16
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let originY = textView.textContainerOrigin.y
        let attributes: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: textColor]
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)

        func draw(_ number: Int, lineRect: NSRect) {
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let labelY = lineRect.minY + originY - visible.minY + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: labelY), withAttributes: attributes)
        }

        layout.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, fragmentGlyphs, _ in
            let chars = layout.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            if self.index.isLineStart(chars.location) {
                draw(self.index.line(containing: chars.location) + 1, lineRect: lineRect)
            }
        }
        // The empty last line after a trailing newline has no fragment of its own.
        let extra = layout.extraLineFragmentRect
        if extra.height > 0, textView.string.hasSuffix("\n") || textView.string.isEmpty {
            draw(index.lineCount, lineRect: extra)
        }
    }
}
