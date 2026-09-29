import SwiftUI
import AppKit

// Keyboard model for `ClipListView`: one key handler shared by the search field
// and the focusable list container (KEY-06), 2D grid navigation (KEY-03),
// range selection (KEY-04), Cmd+A/C/Z, two-stage Escape (PNL-11), Cmd+Option+1..9
// quick paste (FEAT-03), undoable deletes (KEY-11) and the event monitor.

extension ClipListView {
    /// Scroll anchor id at the top of the list (KEY-01).
    static let topAnchorID = "clip-list-top"

    // MARK: - Grid geometry

    /// Navigator for the current pane: real column count and section partition.
    func gridNavigator(for clips: [Clip]) -> GridNavigator {
        let columns = selection == .suggestions ? 1 : currentColumnCount()
        let lengths = selection == .suggestions ? [clips.count] : sections(for: clips).map { $0.rows.count }
        return GridNavigator(columns: columns, sectionLengths: lengths, pageRows: max(1, Int(listHeight / 90)))
    }

    /// Reconciles the range model with mutations that bypassed it.
    func syncRangeModel() {
        rangeModel.adopt(published: selectedClipIDs, cursor: selectedClip?.id)
    }

    /// Moves the cursor to `index`, extending or collapsing the selection.
    func moveCursor(to index: Int, extend: Bool) {
        let clips = visibleClips
        guard clips.indices.contains(index), let id = clips[index].id else { return }
        syncRangeModel()
        if extend {
            rangeModel.extend(to: id, order: clips.compactMap(\.id))
        } else {
            rangeModel.reset(to: id)
        }
        selectedClipIDs = rangeModel.published
        selectedIndex = index
    }

    /// Applies a navigation key.
    func navigate(_ move: GridNavigator.Move, extend: Bool) {
        let clips = visibleClips
        guard !clips.isEmpty else { return }
        let target = gridNavigator(for: clips).target(from: selectedIndex, move: move, stickyColumn: navColumn)
        switch move {
        case .up, .down, .pageUp, .pageDown: navColumn = target.column
        default: navColumn = nil
        }
        moveCursor(to: target.index, extend: extend)
    }

    // MARK: - Key handling

    /// Single entry point for keys from the search field and the list container.
    func handleKey(_ press: KeyPress, from source: PanelFocusTarget) -> KeyPress.Result {
        let mods = press.modifiers
        let command = mods.contains(.command)
        let searchEditing = source == .search && !store.query.isEmpty

        if let move = navigationMove(for: press.key), !command, !mods.contains(.option) {
            // Left/Right/Home/End belong to the caret while the field has text.
            if searchEditing, [.left, .right, .home, .end].contains(move) { return .ignored }
            navigate(move, extend: mods.contains(.shift))
            return .handled
        }
        if press.key == .return {
            pasteSelected(shiftHeld: mods.contains(.shift))
            return .handled
        }
        if let result = handleQuickLookKey(press, source: source) { return result }
        if press.key == .escape {
            performEscape()
            return .handled
        }
        if command, press.key == .delete {
            if selectedClipIDs.count >= 2 { requestBatchDelete() } else if let clip = selectedClip { requestDelete(clip) } else { return .ignored }
            return .handled
        }
        if let digit = press.key.character.wholeNumberValue, (1...9).contains(digit), press.key.character.isNumber {
            return handleDigit(press, source: source)
        }
        if command { return handleCommandKey(press, source: source) }
        if source == .list, isPrintable(press) {
            store.query += press.characters
            focusTarget = .search
            return .handled
        }
        return .ignored
    }

    private func navigationMove(for key: KeyEquivalent) -> GridNavigator.Move? {
        switch key {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        default: return nil
        }
    }

    private func isPrintable(_ press: KeyPress) -> Bool {
        guard press.modifiers.isSubset(of: [.shift]), let scalar = press.characters.unicodeScalars.first,
              !press.characters.allSatisfy(\.isWhitespace) else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    private func handleDigit(_ press: KeyPress, source: PanelFocusTarget) -> KeyPress.Result {
        let mods = press.modifiers
        let digitChar = press.key.character
        let clips = visibleClips
        // Cmd+Option+1..9: quick paste of the Nth visible clip, in every pane.
        if mods.contains(.command), mods.contains(.option) {
            guard let index = QuickPasteMap.index(forDigit: digitChar, visibleCount: clips.count) else { return .handled }
            onPaste(clips[index], settings.pastePlainTextByDefault)
            return .handled
        }
        // Suggestions: bare digit pastes the Nth suggestion while the query is empty.
        if selection == .suggestions, store.query.isEmpty, mods.isEmpty {
            if let index = QuickPasteMap.index(forDigit: digitChar, visibleCount: clips.count) {
                onPaste(clips[index], settings.pastePlainTextByDefault)
            }
            return .handled
        }
        if mods.contains(.command), let digit = digitChar.wholeNumberValue {
            // Cmd+1 = History, Cmd+2... = the Nth category (existing behavior).
            if digit == 1 { selection = .history; return .handled }
            let index = digit - 2
            guard store.categories.indices.contains(index), let categoryID = store.categories[index].id else { return .ignored }
            selection = .category(categoryID)
            return .handled
        }
        if source == .list, isPrintable(press) {
            store.query += press.characters
            focusTarget = .search
            return .handled
        }
        return .ignored
    }

    private func handleCommandKey(_ press: KeyPress, source: PanelFocusTarget) -> KeyPress.Result {
        let fieldSelected = searchSelectionIsNonEmpty
        switch press.key.character {
        case "a":
            let target = SelectAllTarget.resolve(query: store.query, searchHasFocus: source == .search, fieldHasSelection: fieldSelected)
            guard target == .clips else { return .ignored }
            selectAllClips()
            return .handled
        case "c":
            if source == .search, fieldSelected { return .ignored }
            copyActionableClips()
            return .handled
        case "z":
            if source == .search, !store.query.isEmpty { return .ignored }
            return undoLastDelete() ? .handled : .ignored
        case "e":
            guard let clip = selectedClip, clip.contentKind == .text else { return .ignored }
            onEdit(clip)
            return .handled
        case "p":
            guard let clip = selectedClip else { return .ignored }
            store.togglePin(clip)
            return .handled
        default:
            return .ignored
        }
    }

    private var searchSelectionIsNonEmpty: Bool {
        guard let selection = searchSelection else { return false }
        switch selection.indices {
        case .selection(let range): return !range.isEmpty
        case .multiSelection(let ranges): return !ranges.isEmpty
        @unknown default: return false
        }
    }

    // MARK: - Actions

    func selectAllClips() {
        syncRangeModel()
        rangeModel.selectAll(order: visibleClips.compactMap(\.id))
        selectedClipIDs = rangeModel.published
    }

    /// Two-stage Escape: multi-selection, then query, then the panel (PNL-11).
    func performEscape() {
        switch EscapeAction.next(hasMultiSelection: !selectedClipIDs.isEmpty, query: store.query) {
        case .clearSelection:
            syncRangeModel()
            rangeModel.collapseToCursor()
            selectedClipIDs = []
        case .clearQuery:
            store.query = ""
        case .hidePanel:
            onClose()
        }
    }

    /// Cmd+C: copy the selected clip(s) to the clipboard without pasting.
    func copyActionableClips() {
        let clips = actionableClips
        guard !clips.isEmpty else { return }
        if ClipCopyBridge.copy(clips, media: store.database.media) {
            showStatusBanner(clips.count == 1 ? "Copied" : "Copied \(clips.count) clips", severity: .success)
        } else {
            showStatusBanner("Could not copy to the clipboard", severity: .failure)
        }
    }

    /// Deletes `clips` after snapshotting them for Cmd+Z.
    func deleteWithUndo(_ clips: [Clip]) {
        let media = store.database.media
        let snapshots = clips.compactMap { clip in
            ClipUndoBuffer.snapshot(of: clip, categoryIDs: store.categoryIDs(for: clip), media: media)
        }
        ClipUndoBuffer.shared.record(snapshots)
        for clip in clips { store.delete(clip) }
        let undoable = snapshots.count == clips.count
        let noun = clips.count == 1 ? "clip" : "\(clips.count) clips"
        showStatusBanner(undoable ? "Deleted \(noun). \u{2318}Z to undo" : "Deleted \(noun)")
    }

    /// Restores the most recent delete. False when there is nothing to undo.
    @discardableResult
    func undoLastDelete() -> Bool {
        guard let batch = ClipUndoBuffer.shared.popLast() else { return false }
        let database = store.database
        store.performWrite("undoDelete") {
            try ClipUndoBuffer.restore(batch, into: database)
        }
        showStatusBanner(batch.count == 1 ? "Restored clip" : "Restored \(batch.count) clips", severity: .success)
        return true
    }

    // MARK: - Event monitor

    /// Right-click selects the clicked card first (unless already selected) and
    /// Cmd+Option reveals the quick-paste badges.
    func startEventMonitor() {
        eventMonitor.start(
            onRightMouseDown: {
                guard let id = hoveredClipID, !selectedClipIDs.contains(id),
                      let index = visibleClips.firstIndex(where: { $0.id == id }) else { return }
                moveCursor(to: index, extend: false)
            },
            onFlagsChanged: { flags in
                let held = flags.contains(.command) && flags.contains(.option)
                if held != quickPasteBadgesVisible { quickPasteBadgesVisible = held }
            }
        )
    }

    // MARK: - Card decorations

    /// Digit badge (1-9) shown on the first nine cards while Cmd+Option is held,
    /// plus the cursor ring on a multi-selection (KEY-04).
    @ViewBuilder
    func keyboardDecorations(index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if selectedClipIDs.count >= 2, index == selectedIndex {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tokens.accent, lineWidth: 2)
            }
            if quickPasteBadgesVisible, index < 9 {
                KeyCap("\u{2325}\u{2318}\(index + 1)")
                    .padding(6)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Drag-out

extension ClipListView {
    /// Lazy drag payload for a card. The token keeps the existing in-app drop
    /// contracts ("clip:<id>" in History, "reorder:clip:<id>" in a category).
    /// Holding Option at drag start exports a text clip's real text instead.
    func dragItem(for clip: Clip, categoryID: Int64?) -> () -> ClipDragItem {
        let id = clip.id ?? -1
        let token = categoryID == nil ? "clip:\(id)" : "reorder:clip:\(id)"
        let media = store.database.media
        return {
            ClipDragItem.make(
                clip: clip, token: token, media: media,
                isSensitive: SensitiveContent.isSensitive(clip: clip),
                optionHeld: NSEvent.modifierFlags.contains(.option)
            )
        }
    }
}
