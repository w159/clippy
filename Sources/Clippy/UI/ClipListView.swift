import SwiftUI
import AppKit

/// Content of the popup panel: header, search bar with filter chips, a resizable
/// split between the category sidebar and the main content pane, and a footer. The main
/// pane slides between History and a selected category. Keyboard driven end
/// to end.
struct ClipListView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    let onPaste: (Clip, Bool) -> Void
    let onPasteMany: ([Clip], Bool, Bool) -> Void
    /// Paste a file clip. move == true sends Cmd+Option+V (Finder "Move Item
    /// Here", removing the original); false sends Cmd+V (copy).
    let onPasteFile: (Clip, Bool) -> Void
    let onPrimary: (Clip) -> Void
    let onSendKeystrokes: (Clip) -> Void
    let onEdit: (Clip) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State var selection: PanelSelection = .history
    @State var selectedIndex = 0
    /// True once the user (not auto-open) changed the pane this presentation;
    /// stops Smart Suggestions auto-open from yanking them elsewhere.
    @State var userChangedSelection = false
    /// Set just before auto-open assigns `selection` so the change handler
    /// does not count it as a manual change.
    @State var isAutoOpeningSuggestions = false
    /// Explicit multi-selection by clip ID. Empty means "no multi-selection";
    /// in that case the keyboard-anchored `selectedIndex`/`selectedClip` is the
    /// single active clip. Plain click clears this back to empty.
    @State var selectedClipIDs: Set<Int64> = []

    @State var categoryCreationClip: Clip?
    /// The ID of the clip whose title is currently being edited inline.
    @State var renamingClipID: Int64?
    /// Current toast/banner content (see `PanelStatusPolicy`); nil when none.
    @State var statusItem: PanelStatusItem?
    /// Retry action for `statusItem`, nil when it has none.
    @State var statusRetry: (() -> Void)?
    /// Query text whose parser warnings the user dismissed.
    @State var dismissedWarningQuery: String?
    /// True while the Cmd+K command palette is open.
    @State var paletteVisible = false
    /// User opened the filter chip row via the filter button.
    @State var filtersExpanded = false
    /// The ID of the keyboard-anchored clip, tracked across DB pulses so a
    /// background capture does not yank the highlight (audit: selection reset on
    /// every DB pulse). Re-indexed to the anchored clip's new position when
    /// store.clips republishes.
    @State var anchoredClipID: Int64?
    /// The clip awaiting delete confirmation. Every delete path (hover button,
    /// context menu, Cmd-Delete) routes through this single piece of state so
    /// there is one confirmation entry point and deletion is never destructive
    /// without a prompt.
    @State var clipPendingDeletion: Clip?
    /// The clips awaiting batch-delete confirmation. Nil when no batch delete is
    /// pending; routes every multi-selection delete through one confirmation gate.
    @State var batchDeletePending: [Clip]?
    /// The clip waiting for the user to confirm a large keystroke action. Nil
    /// when the clip is below the warn threshold or no action is pending.
    @State var clipPendingKeystrokes: Clip?
    /// Which control holds keyboard input: the search field or the list container (KEY-06).
    @FocusState var focusTarget: PanelFocusTarget?
    /// Selection inside the search field, for Cmd+A routing (KEY-05).
    @State var searchSelection: TextSelection?
    /// Anchor + cursor selection model (KEY-04); republished into `selectedClipIDs`.
    @State var rangeModel = RangeSelectionModel()
    /// Column remembered across consecutive Up/Down moves (KEY-03).
    @State var navColumn: Int?
    /// Live height of the clip list, used to size Page Up / Page Down.
    @State var listHeight: CGFloat = 0
    /// The card under the pointer, used to resolve right-click selection (KEY-07).
    @State var hoveredClipID: Int64?
    /// True while Cmd+Option is held: shows the quick-paste digit badges (FEAT-03).
    @State var quickPasteBadgesVisible = false
    /// Local event monitor for right-click and modifier changes.
    @State var eventMonitor = PanelEventMonitor()
    /// AI runner used by the context-menu AI submenu.
    @StateObject var aiRunner = AIActionRunner()
    /// The clip the AI action is being run against (needed so onApply can write back).
    @State var aiTargetClip: Clip?
    /// The action awaiting an instruction from the user (for {instruction} templates).
    /// Non-nil drives the instruction prompt alert.
    @State var aiInstructionAction: AIAction?
    /// The clip the pending instruction action will run against.
    @State var aiInstructionClip: Clip?
    /// The text the user types into the instruction prompt.
    @State var aiInstructionText: String = ""
    /// The clip handed to the AI Assistant as conversation context. Captured
    /// from the anchored selection when the pane switches to .assistant, or set
    /// explicitly by "Open AI Assistant" in a clip's AI menu.
    @State var assistantContextClip: Clip?
    /// True while an explicit "Open AI Assistant" set the context clip, so the
    /// selection-change handler does not overwrite it with the anchored clip.
    @State var assistantContextExplicit = false
    /// The clip ID currently being hovered over during a within-category reorder drag.
    /// Shared across all category-section rows so the insertion line can track the target.
    @State var draggingOverClipID: Int64?
    /// Clip awaiting a "Show in Timeline" reveal. Set by the context-menu
    /// action, consumed once the target pane's clips contain it (the query
    /// clear and pane switch land on separate view updates).
    @State var pendingRevealClipID: Int64?
    /// Live width of the clip list, used to cap the user's column choice so
    /// grid cards never drop below a readable minimum width (cards used to
    /// overflow their cells and collide at 3-4 columns in a narrow panel).
    @State var listWidth: CGFloat = 0
    /// Hover state for the end-of-list clip reorder target. The per-row
    /// `.reorderDropDestination` only inserts before a target row, so the slot
    /// after the last clip in a category pane is unreachable without this
    /// trailing target. See `reorderTrailingDropDestination`.
    @State var draggingOverTrailingClip = false
    /// Feature integration state: sheets, preview column width, auto-file tray, smart filter (see `ClipListView+Features`).
    @State var features = ClipListFeatureState()
    /// Smart collections shown in the sidebar; its rule filters History.
    @StateObject var smartCollections = SmartCollectionSelection()
    /// Preview column opt-in, observed so the Settings pane and palette toggles apply live.
    @AppStorage(PreviewColumnPreferences.enabledKey) var previewColumnEnabled = false

    /// Active theme token table; every color below reads from this.
    var tokens: ThemeTokens { settings.theme }

    /// Mirrors `ClipStore.displayLimit` (private there). Used only to surface the
    /// history cap to the user via a footer hint; if the store changes its cap,
    /// update this mirror (audit: history hard-capped at 300 with no indication).
    static let displayLimit = 300

    /// Clips shown for the current selection, in keyboard-navigation order.
    /// History is the "loose" root: once a clip is filed into any category it
    /// behaves like a file moved into a folder and no longer appears here, only
    /// inside that category's pane.
    ///
    /// Category panes return clips in user-defined sortOrder (drag-reorderable).
    /// History stays createdAt DESC (a live recency feed, not reorderable).
    var visibleClips: [Clip] { clips(for: selection) }

    /// Clips for an arbitrary pane selection. Split from `visibleClips` so the
    /// selection-change handler can resolve the outgoing pane's anchored clip
    /// (for the assistant context chip) after `selection` has already changed.
    func clips(for selection: PanelSelection) -> [Clip] {
        switch selection {
        case .history:
            return smartFiltered(store.clips.filter { !store.isPinned($0) })
        case .category(let categoryID):
            return store.clipsForCategory(categoryID)
        case .onePassword:
            return []
        case .snippets, .pasteStack:
            return []
        case .scripts:
            return []
        case .assistant:
            return []
        case .aiActions:
            return []
        case .suggestions:
            return store.suggestions.map(\.clip)
        }
    }

    /// Non-nil when the current selection is a category pane.
    var activeCategoryID: Int64? {
        if case .category(let id) = selection { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            if SearchFieldPolicy.showsSearchField(for: selection) { searchBar }
            errorBanners
            splitContent
            Divider()
            if selectedClipIDs.count >= 2 { batchActionBar; Divider() }
            footer
        }
        .background(ThemedPanelBackground(tokens: tokens, opacity: settings.panelOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        .tint(tokens.accent)
        .overlay { paletteOverlay }
        .background(paletteShortcut)
        .ocrResultSheet(store: store, onPaste: onPaste)
        .modifier(ClipListFeatureModifier(store: store, smartCollections: smartCollections, features: $features,
                                          selectedClip: selectedClip))
        .onReceive(NotificationCenter.default.publisher(for: .clippyPasteResult)) { handlePasteResult($0.object) }
        .onChange(of: store.storageWarning) { _, usage in handleStorageWarning(usage) }
        .onChange(of: store.categoryError) { _, message in handleCategoryError(message) }
        .onAppear { startEventMonitor() }
        .onDisappear { eventMonitor.stop() }
        // Preserve selection across DB pulses instead of wiping it on every
        // capture/membership write (audit: selection reset on every DB pulse).
        // Re-anchor on the same clip if it survived (its index may have shifted
        // due to a new capture prepended at the top); otherwise reset to the
        // first row. Intersect the explicit multi-selection with the surviving
        // clip ids so removed clips drop out but the rest of the selection stays.
        .onChange(of: store.clips) { _, _ in
            let newIDs = Set(visibleClips.compactMap { $0.id })
            selectedClipIDs.formIntersection(newIDs)
            rangeModel.prune(keeping: newIDs)
            if let anchor = anchoredClipID,
               let newIndex = visibleClips.firstIndex(where: { $0.id == anchor }) {
                selectedIndex = newIndex
            } else {
                selectedIndex = 0
                anchoredClipID = visibleClips.first?.id
            }
            attemptPendingReveal()
        }
        .onChange(of: store.suggestionsState) { _, newState in
            // Auto-open: show the Suggestions pane once results land, unless
            // the user already navigated somewhere this presentation.
            guard settings.suggestionsEnabled, settings.suggestionsAutoOpen,
                  newState == .ready, !store.suggestions.isEmpty,
                  !userChangedSelection, selection != .suggestions else { return }
            isAutoOpeningSuggestions = true
            selection = .suggestions
        }
        .onChange(of: selection) { oldValue, newValue in
            if isAutoOpeningSuggestions {
                isAutoOpeningSuggestions = false
            } else {
                userChangedSelection = true
            }
            // Opening the assistant carries the anchored text clip in as the
            // context chip. Resolve against the OUTGOING pane's clips because
            // `selection` (and thus visibleClips) has already switched. An
            // explicit "Open AI Assistant" set the clip itself; do not clobber it.
            if newValue == .assistant {
                if assistantContextExplicit {
                    assistantContextExplicit = false
                } else {
                    let outgoing = clips(for: oldValue)
                    if outgoing.indices.contains(selectedIndex),
                       outgoing[selectedIndex].contentKind == .text {
                        assistantContextClip = outgoing[selectedIndex]
                    }
                }
            }
            selectedIndex = 0
            selectedClipIDs = []
            attemptPendingReveal()
        }
        // AI action sheet, shown when a context-menu AI action produces a proposal.
        .sheet(isPresented: Binding(
            get: { aiRunner.isPresenting },
            set: { if !$0 { aiRunner.reset() } }
        )) {
            AIActionSheet(runner: aiRunner) { proposal in
                guard let clip = aiTargetClip else { aiRunner.reset(); return }
                handleAIProposal(proposal, for: clip)
                aiRunner.reset()
            }
        }
        // Instruction prompt for AI actions whose template needs {instruction}.
        // A sheet with a multi-line field, not an alert: instructions like
        // "rewrite this as a polite decline, keep the dates" need room to type.
        .sheet(isPresented: Binding(
            get: { aiInstructionAction != nil },
            set: { if !$0 { aiInstructionAction = nil; aiInstructionClip = nil } }
        )) {
            instructionSheet
        }
        // Single confirmation gate for every delete path. The button is marked
        // destructive so it reads red and is not the default action.
        .alert(
            "Delete this clip?",
            isPresented: Binding(
                get: { clipPendingDeletion != nil },
                set: { if !$0 { clipPendingDeletion = nil } }
            ),
            presenting: clipPendingDeletion
        ) { clip in
            Button("Delete", role: .destructive) { deleteWithUndo([clip]) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This permanently removes the clip from your history.")
        }
        // Batch delete confirmation. Mirrors the single-clip gate above so the
        // multi-selection delete path is just as non-destructive.
        .alert(
            "Delete \(batchDeletePending?.count ?? 0) clips?",
            isPresented: Binding(
                get: { batchDeletePending != nil },
                set: { if !$0 { batchDeletePending = nil } }
            ),
            presenting: batchDeletePending
        ) { clips in
            Button("Delete", role: .destructive) { performBatchDelete(clips) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This permanently removes the selected clips from your history.")
        }
        // Confirmation gate for large keystroke actions so an accidental click
        // does not type thousands of characters into the active app.
        .alert(
            "Type as keystrokes?",
            isPresented: Binding(
                get: { clipPendingKeystrokes != nil },
                set: { if !$0 { clipPendingKeystrokes = nil } }
            ),
            presenting: clipPendingKeystrokes
        ) { clip in
            Button("Type \(clip.contentText.count.formatted()) characters", role: .destructive) {
                onSendKeystrokes(clip)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This will type the clip into the active app character by character.")
        }
    }

}
