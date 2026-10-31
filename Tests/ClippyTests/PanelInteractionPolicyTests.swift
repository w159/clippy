import XCTest
@testable import Clippy

/// Pure rules behind the panel's keyboard, focus and selection fixes.
@MainActor
final class PanelInteractionPolicyTests: XCTestCase {
    private func clip(_ id: Int64, createdAt: Date = Date()) -> Clip {
        var clip = makeTextClip("x", createdAt: createdAt)
        clip.id = id
        return clip
    }

    // MARK: - 1. Actions target what is highlighted

    /// Seeded fault: acting on the cursor row when one clip is selected elsewhere.
    func testActionTargetsTheHighlightedClipAfterCmdClickDeselect() {
        XCTAssertEqual(ActionTargetPolicy.ids(selected: [1], cursorID: 2, order: [1, 2, 3]), [1])
        XCTAssertEqual(ActionTargetPolicy.ids(selected: [], cursorID: 2, order: [1, 2, 3]), [2])
        XCTAssertEqual(ActionTargetPolicy.ids(selected: [3, 1], cursorID: 2, order: [1, 2, 3]), [1, 3])
        XCTAssertEqual(ActionTargetPolicy.ids(selected: [], cursorID: nil, order: [1]), [])
    }

    // MARK: - 2. Cmd+Backspace in the search field

    /// Seeded fault: deleting a clip while editing the query text.
    func testCmdDeleteEditsTextInSearchFieldWithText() {
        XCTAssertFalse(CommandDeletePolicy.deletesClips(source: .search, query: "inv"))
        XCTAssertTrue(CommandDeletePolicy.deletesClips(source: .search, query: ""))
        XCTAssertTrue(CommandDeletePolicy.deletesClips(source: .list, query: "inv"))
    }

    // MARK: - 3 and 6. Cursor after the anchored clip disappears

    /// Seeded fault: falling back to row 0 when the anchored clip is gone.
    func testCursorLandsOnNeighbourAfterDelete() {
        let after = [clip(1), clip(2), clip(4), clip(5)]
        XCTAssertEqual(ResultSelectionPolicy.index(in: after, anchor: 3, followsTop: false, previousIndex: 2), 2)
        // Deleting the last row clamps to the new last row.
        XCTAssertEqual(ResultSelectionPolicy.index(in: after, anchor: 6, followsTop: false, previousIndex: 4), 3)
        XCTAssertEqual(ResultSelectionPolicy.index(in: [], anchor: 6, followsTop: false, previousIndex: 4), 0)
        // A surviving anchor and a query-driven jump are unchanged.
        XCTAssertEqual(ResultSelectionPolicy.index(in: after, anchor: 5, followsTop: false, previousIndex: 0), 3)
        XCTAssertEqual(ResultSelectionPolicy.index(in: after, anchor: 5, followsTop: true, previousIndex: 3), 0)
    }

    // MARK: - 4. Escape

    /// Seeded fault: Escape hiding a pinned panel or ignoring the setting.
    func testEscapeRespectsSettingAndPin() {
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "", hideOnEscape: false, panelPinned: false), .stay)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "", hideOnEscape: true, panelPinned: true), .stay)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "", hideOnEscape: true, panelPinned: false), .hidePanel)
        // Selection and query are still dismissed first, pinned or not.
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: true, query: "a", hideOnEscape: false, panelPinned: true), .clearSelection)
        XCTAssertEqual(EscapeAction.next(hasMultiSelection: false, query: "a", hideOnEscape: false, panelPinned: true), .clearQuery)
    }

    // MARK: - 5. Suggestions pane

    /// Seeded fault: digits typed into the search field pasting a suggestion.
    func testDigitsInSearchFieldAreText() {
        XCTAssertTrue(SuggestionDigitPolicy.pastesSuggestion(selection: .suggestions, source: .list, query: ""))
        XCTAssertFalse(SuggestionDigitPolicy.pastesSuggestion(selection: .suggestions, source: .search, query: ""))
        XCTAssertFalse(SuggestionDigitPolicy.pastesSuggestion(selection: .suggestions, source: .list, query: "x"))
        XCTAssertFalse(SuggestionDigitPolicy.pastesSuggestion(selection: .history, source: .list, query: ""))
    }

    /// Seeded fault: a query typed in Suggestions staying on the suggestion list.
    func testQueryInSuggestionsSearchesHistory() {
        XCTAssertTrue(SuggestionsQueryPolicy.redirectsToHistory(selection: .suggestions, query: "invoice"))
        XCTAssertFalse(SuggestionsQueryPolicy.redirectsToHistory(selection: .suggestions, query: "  "))
        XCTAssertFalse(SuggestionsQueryPolicy.redirectsToHistory(selection: .history, query: "invoice"))
    }

    // MARK: - 7. Show in Timeline

    /// Seeded fault: the reveal's query clear resetting the cursor to row 0.
    func testRevealQueryClearIsConsumedOnce() {
        var guardState = RevealQueryGuard()
        guardState.arm(currentQuery: "invoice")
        XCTAssertTrue(guardState.consumeQueryChange())
        XCTAssertFalse(guardState.consumeQueryChange(), "a later real edit must reset the cursor")
    }

    func testRevealWithEmptyQueryDoesNotSwallowTheNextEdit() {
        var guardState = RevealQueryGuard()
        guardState.arm(currentQuery: "")
        XCTAssertFalse(guardState.consumeQueryChange())
    }

    // MARK: - 8 and 10. Focus

    func testFocusAfterRenameReturnsToList() {
        XCTAssertEqual(PanelFocusPolicy.afterRenameEnded(), .list)
    }

    func testFocusFollowsPaneChange() {
        XCTAssertEqual(PanelFocusPolicy.afterPaneChange(previous: .list, showsSearchField: true, hasClips: true), .list)
        XCTAssertEqual(PanelFocusPolicy.afterPaneChange(previous: .list, showsSearchField: true, hasClips: false), .search)
        XCTAssertEqual(PanelFocusPolicy.afterPaneChange(previous: .search, showsSearchField: true, hasClips: true), .search)
        // The sidebar owned focus: leave it alone. Tool panes have no target.
        XCTAssertNil(PanelFocusPolicy.afterPaneChange(previous: nil, showsSearchField: true, hasClips: true))
        XCTAssertNil(PanelFocusPolicy.afterPaneChange(previous: .list, showsSearchField: false, hasClips: true))
    }

    func testFocusFallsBackToSearchWhenListEmpties() {
        XCTAssertEqual(PanelFocusPolicy.afterListEmptied(previous: .list, showsSearchField: true), .search)
        XCTAssertNil(PanelFocusPolicy.afterListEmptied(previous: nil, showsSearchField: true))
        XCTAssertNil(PanelFocusPolicy.afterListEmptied(previous: .list, showsSearchField: false))
    }

    // MARK: - 9. Cmd+K

    /// Seeded fault: the second Cmd+K toggling visibility without returning focus.
    func testSecondCmdKClosesAndRefocuses() {
        let open = PaletteTogglePolicy.next(isVisible: false)
        XCTAssertTrue(open.visible)
        let close = PaletteTogglePolicy.next(isVisible: true)
        XCTAssertFalse(close.visible)
        XCTAssertEqual(close.focus, .search)
    }

    // MARK: - 11. Search results by day

    /// Seeded fault: tier-ordered results repeating a day's header.
    func testSearchResultsGroupByDayNewestDayFirst() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400 * 1.5)
        // Word-start tier (Today, Yesterday) then fragment tier (Today).
        let results = [clip(1, createdAt: now), clip(2, createdAt: yesterday), clip(3, createdAt: now.addingTimeInterval(-60))]
        let ordered = SearchSectionOrder.groupedByBucket(results, bucket: { TimelineBucket.title(for: $0.createdAt) },
                                                         date: { $0.createdAt })
        XCTAssertEqual(ordered.compactMap(\.id), [1, 3, 2])
        let titles = ordered.map { TimelineBucket.title(for: $0.createdAt) }
        var runs: [String] = []
        for title in titles where runs.last != title { runs.append(title) }
        XCTAssertEqual(runs.count, Set(runs).count, "each day header appears once")
    }

    func testOlderTierDoesNotPutAnOlderDayFirst() {
        let now = Date()
        let old = now.addingTimeInterval(-86_400 * 40)
        // Tier one holds only an old clip; tier two holds a recent one.
        let ordered = SearchSectionOrder.groupedByBucket([clip(1, createdAt: old), clip(2, createdAt: now)],
                                                         bucket: { TimelineBucket.title(for: $0.createdAt) },
                                                         date: { $0.createdAt })
        XCTAssertEqual(ordered.compactMap(\.id), [2, 1])
    }

    // MARK: - 13. Context-menu paste

    /// Seeded fault: the menu's Paste ignoring "paste as plain text by default".
    func testContextMenuPasteFollowsDefaultMode() {
        let formatted = PasteMenuPolicy.items(defaultPlain: false)
        XCTAssertFalse(formatted.primaryPlain)
        XCTAssertTrue(formatted.alternate.plain)
        let plain = PasteMenuPolicy.items(defaultPlain: true)
        XCTAssertTrue(plain.primaryPlain)
        XCTAssertFalse(plain.alternate.plain)
        XCTAssertNotEqual(plain.alternate.title, formatted.alternate.title)
    }

    // MARK: - 14. Links and Open Clippy

    /// Seeded fault: a visible but non-key panel only posting a focus request.
    func testOpenPolicyMakesAVisibleNonKeyPanelKey() {
        XCTAssertEqual(PanelOpenPolicy.step(isVisible: false, isKey: false), .show)
        XCTAssertEqual(PanelOpenPolicy.step(isVisible: true, isKey: true), .focusSearch)
        XCTAssertEqual(PanelOpenPolicy.step(isVisible: true, isKey: false), .makeKeyAndFocusSearch)
    }

    /// Seeded fault: the link's arguments dropped before the panel sees them.
    func testLaunchQueueDeliversArgumentsOnceAndExpires() throws {
        var queue = PanelLaunchQueue()
        let now = Date()
        queue.post(.search("invoice"), now: now)
        XCTAssertEqual(queue.take(now: now.addingTimeInterval(1)), .search("invoice"))
        XCTAssertNil(queue.take(now: now.addingTimeInterval(2)))
        queue.post(.reveal(42), now: now)
        XCTAssertNil(queue.take(now: now.addingTimeInterval(PanelLaunchQueue.lifetime + 1)))
        queue.post(.palette, now: now)
        queue.post(.reveal(7), now: now)
        XCTAssertEqual(queue.take(now: now), .reveal(7), "the newest request wins")
    }

    func testLinksParseToTheirArguments() throws {
        let search = try ClippyURL.parse(XCTUnwrap(URL(string: "clippy://search?q=invoice%20due"))).get()
        XCTAssertEqual(search, .search(query: "invoice due"))
        let get = try ClippyURL.parse(XCTUnwrap(URL(string: "clippy://get?id=42"))).get()
        XCTAssertEqual(get, .get(id: 42))
    }

    // MARK: - 15. Category rename

    /// Seeded fault: a duplicate name staying in rename mode after focus loss.
    func testDuplicateRenameCancelsOnFocusLossButRejectsOnReturn() {
        XCTAssertEqual(CategoryRenameOutcome.resolve(draft: " Work ", original: "Home", isDuplicate: true, focusLost: false),
                       .rejectDuplicate)
        XCTAssertEqual(CategoryRenameOutcome.resolve(draft: "Work", original: "Home", isDuplicate: true, focusLost: true), .cancel)
        XCTAssertEqual(CategoryRenameOutcome.resolve(draft: " New ", original: "Home", isDuplicate: false, focusLost: true), .save("New"))
        XCTAssertEqual(CategoryRenameOutcome.resolve(draft: "  ", original: "Home", isDuplicate: false, focusLost: false), .cancel)
        XCTAssertEqual(CategoryRenameOutcome.resolve(draft: "Home", original: "Home", isDuplicate: false, focusLost: false), .cancel)
    }
}
