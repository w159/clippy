import AppKit

/// NSTextView with the code-editing behaviors: Return keeps (and deepens)
/// indentation, Tab / Shift-Tab indent and outdent lines, Cmd+S fires `onSave`,
/// smart substitutions are off, and the bracket next to the caret is matched.
final class CodeTextView: NSTextView {
    var language: CodeLanguage = .plain
    var indentUnit: CodeIndentUnit = .spaces(4)
    var onSave: (() -> Void)?
    var bracketColor: NSColor = .selectedTextBackgroundColor

    private var highlightedBrackets: [NSRange] = []

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "s",
           window?.firstResponder === self, let onSave {
            onSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        let cursor = selectedRange().location
        let result = CodeIndentation.newline(in: string, cursor: cursor, unit: indentUnit, language: language)
        // Replace any selection, then place the caret inside the new indent.
        insertText(result.insert, replacementRange: selectedRange())
        let inserted = (result.insert as NSString).length
        setSelectedRange(NSRange(location: selectedRange().location - inserted + result.caretOffset, length: 0))
    }

    override func insertTab(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 || !(string as NSString).substring(with: range).contains("\n") {
            insertText(indentUnit.string, replacementRange: range)
        } else {
            shiftSelectedLines(outdent: false)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        shiftSelectedLines(outdent: true)
    }

    private func shiftSelectedLines(outdent: Bool) {
        let selection = selectedRange()
        let shifted = CodeIndentation.shiftLines(in: string, range: selection, unit: indentUnit, outdent: outdent)
        guard shifted.replacement != (string as NSString).substring(with: shifted.replacedRange) else { return }
        guard shouldChangeText(in: shifted.replacedRange, replacementString: shifted.replacement) else { return }
        textStorage?.replaceCharacters(in: shifted.replacedRange, with: shifted.replacement)
        didChangeText()
        setSelectedRange(NSRange(location: shifted.replacedRange.location,
                                 length: (shifted.replacement as NSString).length))
    }

    // MARK: Bracket matching

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { updateBracketHighlight() }
    }

    func updateBracketHighlight() {
        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        for range in highlightedBrackets where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        highlightedBrackets = []
        let selection = selectedRange()
        guard selection.length == 0,
              let pair = BracketMatcher.pair(in: string as NSString, caret: selection.location) else { return }
        for index in [pair.0, pair.1] {
            let range = NSRange(location: index, length: 1)
            layout.addTemporaryAttribute(.backgroundColor, value: bracketColor, forCharacterRange: range)
            highlightedBrackets.append(range)
        }
    }

    /// Drops remembered bracket ranges (after the text was replaced wholesale).
    func resetBracketHighlight() { highlightedBrackets = [] }
}
