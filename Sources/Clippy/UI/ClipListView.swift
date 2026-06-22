import SwiftUI
import AppKit

/// Content of the popup panel: search bar, a 75/25 split between the main
/// content pane and the category side pane, and a shortcut footer. The main
/// pane slides between History and a selected category. Keyboard driven end
/// to end.
struct ClipListView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    @State private var selection: PanelSelection = .history
    @State private var selectedIndex = 0
    /// Explicit multi-selection by clip ID. Empty means "no multi-selection";
    /// in that case the keyboard-anchored `selectedIndex`/`selectedClip` is the
    /// single active clip. Plain click clears this back to empty.
    @State private var selectedClipIDs: Set<Int64> = []

    /// The clips batch actions operate on: the explicit multi-selection if any,
    /// otherwise the single keyboard-anchored clip.
    private var actionableClips: [Clip] {
        if selectedClipIDs.isEmpty {
            return selectedClip.map { [$0] } ?? []
        }
        return visibleClips.filter { clip in clip.id.map { selectedClipIDs.contains($0) } ?? false }
    }
    @State private var categoryCreationClip: Clip?
    /// The ID of the clip whose title is currently being edited inline.
    @State private var renamingClipID: Int64?
    /// Typed status banner content. Replaces the old plain-string banner so
    /// success and failure render with distinct severity colors, an SF Symbol,
    /// and an optional retry action (audit: OCR banner renders success/failure
    /// identically).
    private enum BannerSeverity { case success, failure, info }
    @State private var bannerMessage: String?
    @State private var bannerSeverity: BannerSeverity = .info
    /// Retry action shown as a button on failure banners. nil for auto-dismissed
    /// info/success banners; non-nil banners persist until the user acts.
    @State private var bannerRetry: (() -> Void)?
    /// ID of the clip currently being processed by OCR so the card can show a spinner.
    @State private var ocrProcessingClipID: Int64?
    /// The ID of the keyboard-anchored clip, tracked across DB pulses so a
    /// background capture does not yank the highlight (audit: selection reset on
    /// every DB pulse). Re-indexed to the anchored clip's new position when
    /// store.clips republishes.
    @State private var anchoredClipID: Int64?
    /// The clip awaiting delete confirmation. Every delete path (hover button,
    /// context menu, Cmd-Delete) routes through this single piece of state so
    /// there is one confirmation entry point and deletion is never destructive
    /// without a prompt.
    @State private var clipPendingDeletion: Clip?
    /// The clips awaiting batch-delete confirmation. Nil when no batch delete is
    /// pending; routes every multi-selection delete through one confirmation gate.
    @State private var batchDeletePending: [Clip]?
    /// The clip waiting for the user to confirm a large keystroke action. Nil
    /// when the clip is below the warn threshold or no action is pending.
    @State private var clipPendingKeystrokes: Clip?
    @FocusState private var searchFocused: Bool
    /// AI runner used by the context-menu AI submenu.
    @StateObject private var aiRunner = AIActionRunner()
    /// The clip the AI action is being run against (needed so onApply can write back).
    @State private var aiTargetClip: Clip?
    /// The action awaiting an instruction from the user (for {instruction} templates).
    /// Non-nil drives the instruction prompt alert.
    @State private var aiInstructionAction: AIAction?
    /// The clip the pending instruction action will run against.
    @State private var aiInstructionClip: Clip?
    /// The text the user types into the instruction prompt.
    @State private var aiInstructionText: String = ""
    /// The clip ID currently being hovered over during a within-category reorder drag.
    /// Shared across all category-section rows so the insertion line can track the target.
    @State private var draggingOverClipID: Int64?

    /// Hover state for the end-of-list clip reorder target. The per-row
    /// `.reorderDropDestination` only inserts before a target row, so the slot
    /// after the last clip in a category pane is unreachable without this
    /// trailing target. See `reorderTrailingDropDestination`.
    @State private var draggingOverTrailingClip = false

    /// Active theme token table; every color below reads from this.
    private var tokens: ThemeTokens { settings.theme }

    /// Mirrors `ClipStore.displayLimit` (private there). Used only to surface the
    /// history cap to the user via a footer hint; if the store changes its cap,
    /// update this mirror (audit: history hard-capped at 300 with no indication).
    private static let displayLimit = 300

    /// Clips shown for the current selection, in keyboard-navigation order.
    /// History is the "loose" root: once a clip is filed into any category it
    /// behaves like a file moved into a folder and no longer appears here, only
    /// inside that category's pane.
    ///
    /// Category panes return clips in user-defined sortOrder (drag-reorderable).
    /// History stays createdAt DESC (a live recency feed, not reorderable).
    private var visibleClips: [Clip] {
        switch selection {
        case .history:
            return store.clips.filter { !store.isPinned($0) }
        case .category(let categoryID):
            return store.clipsForCategory(categoryID)
        case .onePassword:
            return []
        case .scripts:
            return []
        case .assistant:
            return []
        }
    }

    /// Non-nil when the current selection is a category pane.
    private var activeCategoryID: Int64? {
        if case .category(let id) = selection { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                isPinned: settings.panelPinned,
                onTogglePin: { settings.panelPinned.toggle() },
                onOpenSettings: onOpenSettings,
                onClose: onClose
            )
            Divider()
            searchBar
            // Surface search and observation failures that were previously
            // swallowed, each with a Retry that re-runs the failed pipeline
            // (audit: search failures silently swallowed; observation errors
            // only logged).
            if store.searchError != nil || store.observationError != nil {
                VStack(spacing: 0) {
                    if let err = store.searchError {
                        errorBanner(err, retry: { store.retrySearch() })
                        Divider()
                    }
                    if let err = store.observationError {
                        errorBanner(err, retry: { store.retryObservation() })
                    }
                }
                Divider()
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    mainPane
                        .frame(width: max(0, geo.size.width - sidePaneWidth(geo)))
                    Divider()
                    CategorySidePane(store: store, selection: $selection)
                        .frame(width: sidePaneWidth(geo) - 1)
                }
            }
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
        // Preserve selection across DB pulses instead of wiping it on every
        // capture/membership write (audit: selection reset on every DB pulse).
        // Re-anchor on the same clip if it survived (its index may have shifted
        // due to a new capture prepended at the top); otherwise reset to the
        // first row. Intersect the explicit multi-selection with the surviving
        // clip ids so removed clips drop out but the rest of the selection stays.
        .onChange(of: store.clips) { _, _ in
            let newIDs = Set(visibleClips.compactMap { $0.id })
            selectedClipIDs.formIntersection(newIDs)
            if let anchor = anchoredClipID,
               let newIndex = visibleClips.firstIndex(where: { $0.id == anchor }) {
                selectedIndex = newIndex
            } else {
                selectedIndex = 0
                anchoredClipID = visibleClips.first?.id
            }
        }
        .onChange(of: selection) { _, _ in selectedIndex = 0; selectedClipIDs = [] }
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
        .alert(aiInstructionAction?.name ?? "AI Action",
               isPresented: Binding(
                get: { aiInstructionAction != nil },
                set: { if !$0 { aiInstructionAction = nil; aiInstructionClip = nil } }
               )) {
            TextField("Instruction", text: $aiInstructionText)
            Button("Run") {
                let trimmed = aiInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let action = aiInstructionAction, let clip = aiInstructionClip, !trimmed.isEmpty {
                    runAIActionNow(action, on: clip, instruction: trimmed)
                }
                aiInstructionAction = nil
                aiInstructionClip = nil
            }
            Button("Cancel", role: .cancel) {
                aiInstructionAction = nil
                aiInstructionClip = nil
            }
        } message: {
            Text(aiInstructionPromptMessage)
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
            Button("Delete", role: .destructive) { store.delete(clip) }
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
        } message: { clip in
            Text("This will type the clip into the active app character by character.")
        }
    }

    /// Stages a clip for deletion behind the confirmation alert. All delete
    /// entry points call this instead of store.delete directly.
    private func requestDelete(_ clip: Clip) {
        clipPendingDeletion = clip
    }

    // MARK: - Batch actions

    /// Stages the current multi-selection for deletion behind the batch alert.
    private func requestBatchDelete() {
        let clips = actionableClips
        guard !clips.isEmpty else { return }
        batchDeletePending = clips
    }

    /// Deletes each clip via the same single-clip store call used by the
    /// confirmation alert, then clears the selection.
    private func performBatchDelete(_ clips: [Clip]) {
        for clip in clips { store.delete(clip) }
        selectedClipIDs = []
    }

    /// Generate and apply an AI title for every selected text clip, non-interactively.
    /// Runs on the main actor (network awaits suspend off-main); each title is set
    /// via the store's title setter, so clip content is never overwritten.
    /// Pass `targets` to retry just the failed subset; omit it to run on the
    /// current selection (audit: batch AI title failures logged but not surfaced).
    private func runBatchAITitles(targets retryTargets: [Clip]? = nil) {
        let targets = retryTargets ?? actionableClips.filter { $0.contentKind == .text }
        guard !targets.isEmpty else { return }
        guard case .success(let service) = AIService.fromSettings() else {
            showStatusBanner("AI isn't configured. Open Settings to set it up.")
            return
        }
        guard let titleAction = AIActionStore.shared.actions.first(where: { $0.name == "Suggest Title" })
            ?? AIActionStore.shared.actions.first else {
            showStatusBanner("No AI title action available.")
            return
        }
        if retryTargets == nil { selectedClipIDs = [] }
        showStatusBanner("Titling \(targets.count) clip\(targets.count == 1 ? "" : "s")...")
        Task { @MainActor in
            var done = 0
            var failed: [Clip] = []
            for clip in targets {
                do {
                    let proposal = try await service.run(action: titleAction, on: clip.contentText)
                    let title = AIService.sanitizeTitle(proposal.proposed)
                    if !title.isEmpty { store.renameClip(clip, userTitle: title) }
                    done += 1
                } catch {
                    failed.append(clip)
                    ClippyLog.error("Batch AI title failed: \(error)", category: ClippyLog.ai)
                }
            }
            if failed.isEmpty {
                showStatusBanner("Titled \(done) of \(targets.count) clip\(targets.count == 1 ? "" : "s").", severity: .success)
            } else {
                showStatusBanner(
                    "Titled \(done) of \(targets.count). \(failed.count) failed.",
                    severity: .failure,
                    retry: { runBatchAITitles(targets: failed) }
                )
            }
        }
    }

    /// Routes a "send keystrokes" request through a confirmation dialog when
    /// the clip exceeds the warn threshold, otherwise fires immediately.
    private func requestSendKeystrokes(_ clip: Clip) {
        if clip.contentText.count > settings.keystrokeWarnThreshold {
            clipPendingKeystrokes = clip
        } else {
            onSendKeystrokes(clip)
        }
    }

    /// Side pane takes a quarter of the panel but never less than 150pt.
    private func sidePaneWidth(_ geo: GeometryProxy) -> CGFloat {
        max(150, geo.size.width * 0.25)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if selection == .history {
                    paneContent
                        .transition(paneTransition(edge: .leading))
                } else {
                    paneContent
                        .id(selection)
                        .transition(paneTransition(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Background behind the scrolling cards; tracks the transparency slider.
            .background(tokens.scrollBackground.opacity(settings.panelOpacity))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
            .clipped()

            // MARK: Status banner (OCR + batch AI outcomes)
            if let message = bannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: bannerSymbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(bannerColor)
                    Text(message)
                        .font(PanelTypography.metadata(settings))
                        .foregroundStyle(tokens.textPrimary)
                        .lineLimit(3)
                    if let retry = bannerRetry {
                        Spacer()
                        Button("Retry") { retry() }
                            .buttonStyle(.plain)
                            .foregroundStyle(bannerColor)
                            .font(PanelTypography.metadata(settings).weight(.semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(bannerColor.opacity(0.4), lineWidth: 1)
                )
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: bannerMessage)
    }

    /// Severity-driven color for the status banner (audit: success/failure
    /// rendered identically).
    private var bannerColor: Color {
        switch bannerSeverity {
        case .success: return tokens.success
        case .failure: return tokens.danger
        case .info:    return tokens.textSecondary
        }
    }

    /// Severity-driven SF Symbol for the status banner.
    private var bannerSymbol: String {
        switch bannerSeverity {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private func paneTransition(edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }

    @ViewBuilder
    private var paneContent: some View {
        if selection == .scripts {
            ScriptsPanelView(store: store, onOpenSettings: onOpenSettings)
        } else if selection == .onePassword {
            OnePasswordView()
        } else if selection == .assistant {
            AIAssistantPanelView(store: store, onOpenSettings: onOpenSettings)
        } else if visibleClips.isEmpty {
            emptyState
        } else {
            sectionedList
        }
    }

    // MARK: - Header

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.textSecondary)
            TextField("Search clipboard history", text: $store.query)
                .textFieldStyle(.plain)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
                .focused($searchFocused)
                .onKeyPress(keys: [.downArrow]) { press in
                    // Shift+Arrow extends the multi-selection from the keyboard
                    // anchor instead of just moving it (audit: arrows cannot
                    // extend multi-selection).
                    if press.modifiers.contains(.shift) {
                        extendSelection(by: 1)
                    } else {
                        moveSelection(by: 1)
                    }
                    return .handled
                }
                .onKeyPress(keys: [.upArrow]) { press in
                    if press.modifiers.contains(.shift) {
                        extendSelection(by: -1)
                    } else {
                        moveSelection(by: -1)
                    }
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    pasteSelected(shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(keys: ["a"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selectedClipIDs = Set(visibleClips.compactMap { $0.id })
                    return .handled
                }
                // Esc clears a multi-selection first; only when there is none does
                // it fall through to closing the panel (the existing behavior).
                .onKeyPress(.escape) {
                    if !selectedClipIDs.isEmpty { selectedClipIDs = []; return .handled }
                    onClose()
                    return .handled
                }
                .onKeyPress(keys: ["e"]) { press in
                    guard press.modifiers.contains(.command),
                          let clip = selectedClip,
                          clip.contentKind == .text
                    else { return .ignored }
                    onEdit(clip)
                    return .handled
                }
                .onKeyPress(keys: ["p"]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
                    store.togglePin(clip)
                    return .handled
                }
                .onKeyPress(keys: [.delete]) { press in
                    guard press.modifiers.contains(.command), let clip = selectedClip else { return .ignored }
                    requestDelete(clip)
                    return .handled
                }
                .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]) { press in
                    guard press.modifiers.contains(.command),
                          let digit = press.characters.first?.wholeNumberValue
                    else { return .ignored }
                    if digit == 1 {
                        selection = .history
                        return .handled
                    }
                    let index = digit - 2
                    guard store.categories.indices.contains(index),
                          let categoryID = store.categories[index].id
                    else { return .ignored }
                    selection = .category(categoryID)
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
        .onAppear { searchFocused = true }
    }

    // MARK: - Sectioned list

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [(index: Int, clip: Clip)]
    }

    private var sections: [Section] {
        let rows = Array(visibleClips.enumerated()).map { (index: $0.offset, clip: $0.element) }
        // Date headers only make sense for the chronological history.
        guard settings.showSectionHeaders, selection == .history else {
            return [Section(id: "all", title: "", rows: rows)]
        }

        var grouped: [(title: String, rows: [(index: Int, clip: Clip)])] = []
        for row in rows {
            let title = sectionTitle(for: row.clip)
            if let last = grouped.indices.last, grouped[last].title == title {
                grouped[last].rows.append(row)
            } else {
                grouped.append((title: title, rows: [row]))
            }
        }
        return grouped.map { Section(id: $0.title, title: $0.title, rows: $0.rows) }
    }

    // Cached formatters: `sections` recomputes on every view update, so building
    // a DateFormatter per clip would be wasteful.
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM"; return f
    }()
    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    /// Maps a clip to its date bucket. Checks run finest-first (day, then week,
    /// then month) so the result is monotonic as dates descend: clips sorted
    /// newest-first never produce an out-of-order or duplicated section.
    private func sectionTitle(for clip: Clip) -> String {
        let cal = Calendar.current
        let now = Date()
        let date = clip.createdAt
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        // Week buckets precede month buckets.
        if let thisWeek = cal.dateInterval(of: .weekOfYear, for: now) {
            if thisWeek.contains(date) { return "This Week" }
            if let lastWeekDay = cal.date(byAdding: .weekOfYear, value: -1, to: now),
               let lastWeek = cal.dateInterval(of: .weekOfYear, for: lastWeekDay),
               lastWeek.contains(date) { return "Last Week" }
        }
        // Month buckets.
        if let thisMonth = cal.dateInterval(of: .month, for: now) {
            if thisMonth.contains(date) { return "This Month" }
            if let lastMonthDay = cal.date(byAdding: .month, value: -1, to: now),
               let lastMonth = cal.dateInterval(of: .month, for: lastMonthDay),
               lastMonth.contains(date) { return "Last Month" }
        }
        // Older clips: month name, with the year appended outside the current year.
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return Self.monthFormatter.string(from: date)
        }
        return Self.monthYearFormatter.string(from: date)
    }

    private var sectionedList: some View {
        // 1 = single-column rows (default). 2-4 = card grid filled left-to-right
        // in reading order (LazyVGrid is row-major).
        let columns = max(1, min(4, settings.clipColumns))
        let gridItems = Array(repeating: GridItem(.flexible(), spacing: 6), count: columns)
        // Precompute per-clip membership/pinned/category lookups once per redraw
        // and pass into each card, instead of re-running store.isPinned /
        // store.categories.filter / store.firstCategory per card per body
        // (audit: per-card store membership queries re-run every redraw).
        let metadata = cardMetadata
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6, pinnedViews: []) {
                    ForEach(sections) { section in
                        if !section.title.isEmpty {
                            sectionHeader(section.title)
                        }
                        if columns > 1 {
                            LazyVGrid(columns: gridItems, alignment: .leading, spacing: 6) {
                                ForEach(section.rows, id: \.clip.id) { row in
                                    card(for: row.clip, at: row.index, metadata: metadata)
                                }
                            }
                        } else {
                            ForEach(section.rows, id: \.clip.id) { row in
                                card(for: row.clip, at: row.index, metadata: metadata)
                            }
                        }
                    }
                    // Audit finding: drag-to-reorder could not drop a clip past
                    // the last clip in a category pane (the per-row destination
                    // only inserts before a target). This trailing target lands
                    // drops past the end and appends via moveClip(before: nil).
                    // History pane has no within-list reorder, so it is excluded.
                    if let categoryID = activeCategoryID, !visibleClips.isEmpty {
                        trailingClipDropZone(inCategory: categoryID)
                    }
                    // Surface the history cap so the user knows older clips are
                    // being truncated (audit: history hard-capped at 300 with no
                    // indication).
                    if selection == .history, store.clips.count >= Self.displayLimit {
                        Text("Showing \(visibleClips.count) most recent")
                            .font(PanelTypography.micro(settings))
                            .foregroundStyle(tokens.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard visibleClips.indices.contains(newIndex) else { return }
                // Keep the anchor id in sync so a DB pulse can re-index onto the
                // same clip instead of jumping to the top.
                anchoredClipID = visibleClips[newIndex].id
                proxy.scrollTo(visibleClips[newIndex].id, anchor: nil)
            }
        }
    }

    /// Per-clip lookups derived once per redraw so the card builder can do O(1)
    /// lookups instead of re-querying the store for every card.
    private struct CardMetadata {
        let isPinned: Bool
        let categoryColors: [Color]
        let pinnedCategory: Category?
    }

    private var cardMetadata: [Int64: CardMetadata] {
        var map: [Int64: CardMetadata] = [:]
        for clip in visibleClips {
            guard let id = clip.id else { continue }
            let memberCats = store.categories.filter { category in
                guard let cid = category.id else { return false }
                return store.categoryIDs(for: clip).contains(cid)
            }
            map[id] = CardMetadata(
                isPinned: store.isPinned(clip),
                categoryColors: memberCats.map { Color(hexString: $0.colorHex) },
                pinnedCategory: store.firstCategory(for: clip)
            )
        }
        return map
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(PanelTypography.micro(settings).weight(.semibold))
                .foregroundStyle(tokens.textSecondary)
                .kerning(0.6)
            Rectangle()
                .fill(tokens.cardBorder.opacity(0.6))
                .frame(height: 1)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    /// Full-width drop target placed after the last clip in a category pane so a
    /// clip reorder drag can land past the end. `moveClip(before: nil)` appends.
    private func trailingClipDropZone(inCategory categoryID: Int64) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .reorderTrailingDropDestination(kind: "clip", isTargeted: $draggingOverTrailingClip) { draggedID in
                store.moveClip(draggedID, inCategory: categoryID, before: nil)
            }
            .accessibilityHidden(true)
    }

    private func card(for clip: Clip, at index: Int, metadata: [Int64: CardMetadata]) -> some View {
        let clipID = clip.id ?? -1
        let categoryID = activeCategoryID
        // Highlight reflects the explicit multi-selection when one exists;
        // otherwise it tracks the single keyboard-anchored row.
        let isSelected: Bool = {
            if selectedClipIDs.isEmpty { return index == selectedIndex }
            return clip.id.map { selectedClipIDs.contains($0) } ?? false
        }()
        let meta = clip.id.flatMap { metadata[$0] }
        return ClipCardView(
            clip: clip,
            isSelected: isSelected,
            isPinned: meta?.isPinned ?? store.isPinned(clip),
            categoryColors: meta?.categoryColors ?? [],
            pinnedCategory: meta?.pinnedCategory,
            isRenaming: Binding(
                get: { renamingClipID == clip.id },
                set: { active in renamingClipID = active ? clip.id : nil }
            ),
            // The card's button action is now a plain single-click select.
            // The actual paste/activate moved to the double-click gesture below
            // so single-click selects and double-click pastes.
            onActivate: { handleRowClick(clip, at: index, modifiers: []) },
            onPaste: { onPaste(clip, settings.pastePlainTextByDefault) },
            onPastePlain: { onPaste(clip, true) },
            onSendKeystrokes: { requestSendKeystrokes(clip) },
            onEdit: { onEdit(clip) },
            onTogglePin: { store.togglePin(clip) },
            onDelete: { requestDelete(clip) },
            onRename: { store.renameClip(clip, userTitle: $0) },
            onPasteFile: { onPasteFile(clip, false) },
            onMoveFile: { onPasteFile(clip, true) }
        )
        .id(clip.id)
        // Drag payload is managed entirely by CategoryReorderModifier so that
        // only one .draggable is ever applied to this view. Two stacked
        // .draggable modifiers on the same view cause SwiftUI to use only the
        // inner one, silently dropping the outer reorder token.
        .modifier(CategoryReorderModifier(
            clipID: clipID,
            categoryID: categoryID,
            draggingOverClipID: $draggingOverClipID,
            store: store
        ))
        // Tap gestures are attached via .simultaneousGesture so they process at
        // the SAME priority as, and concurrently with, the .draggable's own drag
        // gesture instead of competing for recognition. A plain .onTapGesture is
        // a normal-precedence gesture that competes with the view's gestures, and
        // on macOS its mouse-down often claims the press before the drag can
        // begin, so the drag never starts. .simultaneousGesture lets the tap and
        // the drag both be recognized: a click-without-move fires the tap, a
        // press-and-move starts the drag.
        //   Apple docs, "Composing SwiftUI gestures" + simultaneousGesture(_:):
        //   "they all execute when triggered, rather than competing for
        //   recognition ... without one preventing the other from executing."
        //   (developer.apple.com/documentation/swiftui/composing-swiftui-gestures)
        // highPriorityGesture is used ONLY for the double-tap so SwiftUI waits
        // for the double-click timeout before the count:1 tap commits, which
        // stops the single-tap from firing on both clicks of a double-click
        // (audit: single-tap fires on both clicks of a double-click paste). It
        // is NOT applied to the count:1 tap: that stays .simultaneousGesture so
        // the drag (which needs the press-and-move path) still coexists with
        // single-click selection. The earlier "highPriorityGesture hard-blocks
        // the drag" note applied to putting high priority on the tap that
        // competes with the drag; the double-tap does not compete with it.
        //   Double-click -> paste/activate (configurable primary action)
        //   Cmd-click     -> toggle this clip in the multi-selection
        //   Shift-click   -> extend the multi-selection range from the anchor
        //   Plain click   -> handleRowClick with no modifiers (select)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onPrimary(clip) })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            // NSEvent.modifierFlags reads the live keyboard state at click time;
            // TapGesture carries no modifier info of its own.
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                handleRowClick(clip, at: index, modifiers: .command)
            } else if mods.contains(.shift) {
                handleRowClick(clip, at: index, modifiers: .shift)
            } else {
                handleRowClick(clip, at: index, modifiers: [])
            }
        })
        .contextMenu {
            if selectedClipIDs.count >= 2 {
                // Batch variants act on the whole multi-selection.
                Button("Paste \(selectedClipIDs.count) Sequentially") { onPasteMany(actionableClips, false, settings.pastePlainTextByDefault) }
                Button("Paste \(selectedClipIDs.count) Combined") { onPasteMany(actionableClips, true, settings.pastePlainTextByDefault) }
                Menu("Move \(selectedClipIDs.count) to Category") {
                    ForEach(store.categories) { cat in
                        Button(cat.name) {
                            for clip in actionableClips { if let id = clip.id, let cid = cat.id { store.fileClip(id: id, intoCategory: cid) } }
                            selectedClipIDs = []
                        }
                    }
                }
                if let activeCategoryID = activeCategoryID {
                    Button("Remove \(selectedClipIDs.count) from Category") {
                        for clip in actionableClips { store.setClip(clip, inCategory: activeCategoryID, false) }
                        selectedClipIDs = []
                    }
                }
                Button("Set \(selectedClipIDs.count) Titles with AI") { runBatchAITitles() }
                Divider()
                Button("Delete \(selectedClipIDs.count)", role: .destructive) { requestBatchDelete() }
            } else {
                Button("Paste") { onPaste(clip, false) }
                if clip.contentKind == .file {
                    Button("Move Here (removes original)") { onPasteFile(clip, true) }
                }
                if clip.contentKind == .text {
                    Button("Paste as Plain Text") { onPaste(clip, true) }
                    Divider()
                    Button("Edit...") { onEdit(clip) }
                }
                if clip.contentKind == .image {
                    Divider()
                    Button {
                        runOCR(on: clip)
                    } label: {
                        Label("Extract Text", systemImage: "text.viewfinder")
                    }
                }
                // "Rename..." works for all clip kinds, not just text.
                Button("Rename...") { renamingClipID = clip.id }
                Button(store.isPinned(clip) ? "Unpin" : "Pin") { store.togglePin(clip) }
                if clip.contentKind == .text {
                    aiActionsMenu(for: clip)
                }
                categoriesMenu(for: clip)
                Divider()
                Button("Delete", role: .destructive) { requestDelete(clip) }
            }
        }
        .popover(
            isPresented: Binding(
                get: { categoryCreationClip?.id == clip.id },
                set: { if !$0 { categoryCreationClip = nil } }
            )
        ) {
            CategoryEditorView(category: nil, knownBundleIDs: store.knownBundleIDs) { name, colorHex, iconKind, iconValue in
                // Create the category and file the clip into it in one step.
                if let created = store.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue),
                   let categoryID = created.id,
                   let clipID = clip.id {
                    store.addClip(id: clipID, toCategory: categoryID)
                }
            }
        }
    }

    // MARK: - AI actions context submenu

    @ViewBuilder
    private func aiActionsMenu(for clip: Clip) -> some View {
        let actions = AIActionStore.shared.actions
        if !settings.aiEnabled {
            Menu {
                Text("Enable AI in Settings to use AI actions.")
            } label: {
                Label("AI", systemImage: "sparkles")
            }
        } else {
            Menu {
                ForEach(actions) { action in
                    Button {
                        runAIAction(action, on: clip)
                    } label: {
                        // Use ActionIconView so emoji/appLogo icons render correctly.
                        // SwiftUI menus accept any label content, not just Label().
                        HStack {
                            ActionIconView(kind: action.iconKind, value: action.symbolName)
                            Text(action.name)
                        }
                    }
                }
                if actions.isEmpty {
                    Text("No actions configured.")
                }
                Divider()
                Button("Open AI Assistant") { selection = .assistant }
            } label: {
                Label("AI", systemImage: "sparkles")
            }
        }
    }

    private func runAIAction(_ action: AIAction, on clip: Clip) {
        // Suggest Category must file the clip, not rewrite its body. Route it
        // through suggestCategory so it yields a .category proposal.
        if action.isSuggestCategory {
            aiTargetClip = clip
            let clipText = clip.contentText
            let categoryNames = store.categories.map(\.name)
            aiRunner.run { service in
                try await service.suggestCategory(forText: clipText, categories: categoryNames)
            }
            return
        }
        // Actions whose template references {instruction} need the user's input
        // first; running them blind sends the model a prompt with an empty
        // instruction (e.g. "Translate the following text to .").
        if action.needsInstruction {
            aiInstructionAction = action
            aiInstructionClip = clip
            aiInstructionText = ""
            return
        }
        runAIActionNow(action, on: clip, instruction: "")
    }

    /// Tailored prompt copy per built-in so the field reads naturally
    /// (e.g. "Which language?" for Translate). Falls back to a generic ask.
    private var aiInstructionPromptMessage: String {
        switch aiInstructionAction?.name {
        case "Translate":    return "Which language should this be translated to?"
        case "Change Tone":  return "What tone? (e.g. formal, friendly, concise)"
        case "Rewrite":      return "How should this be rewritten?"
        case "Generate Clip": return "What should the new clip contain?"
        default:             return "Enter an instruction for this action."
        }
    }

    /// Execute the action immediately with the (possibly empty) instruction.
    private func runAIActionNow(_ action: AIAction, on clip: Clip, instruction: String) {
        aiTargetClip = clip
        let clipText = clip.contentText
        aiRunner.run { service in
            try await service.run(action: action, on: clipText, instruction: instruction)
        }
    }

    /// Apply an approved AI proposal to its source clip.
    private func handleAIProposal(_ proposal: AIProposal, for clip: Clip) {
        let text = proposal.proposed
        switch proposal.kind {
        case .category:
            // Suggested category: file the clip into the matched category,
            // leaving the clip body untouched. Match by name against the store.
            if let category = store.categories.first(where: {
                $0.name.caseInsensitiveCompare(text) == .orderedSame
            }), let categoryID = category.id, let clipID = clip.id {
                store.fileClip(id: clipID, intoCategory: categoryID)
                showStatusBanner("Filed under \"\(category.name)\"")
            } else {
                showStatusBanner("No matching category for \"\(text)\"")
            }
        case .rewrite, .title, .summary:
            // proposeEdit disposition: overwrite the clip text in-place.
            store.updateText(of: clip, to: text)
        case .newClip:
            // newClip disposition: insert as a fresh history entry.
            store.saveScriptOutput(text)
        case .copyToClipboard:
            // copyToClipboard disposition: write result to NSPasteboard without
            // touching the source clip, then show a brief status banner.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showStatusBanner("Copied to clipboard")
        }
    }

    /// Show `message` in the status banner with the given severity. Info/success
    /// banners auto-dismiss; failure banners carrying a retry persist until the
    /// user acts so the retry button is reachable (audit: unify dismiss timings;
    /// surface OCR/AI failures with a retry).
    private func showStatusBanner(_ message: String, severity: BannerSeverity = .info, retry: (() -> Void)? = nil) {
        bannerMessage = message
        bannerSeverity = severity
        bannerRetry = retry
        if retry == nil {
            dismissBanner(after: 3)
        }
    }

    /// Single auto-dismiss path for the status banner (audit: 3s vs 2s timings
    /// unified behind one helper).
    private func dismissBanner(after seconds: TimeInterval) {
        let captured = bannerMessage
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if bannerMessage == captured {
                bannerMessage = nil
                bannerRetry = nil
            }
        }
    }

    /// Runs OCR on `clip` and surfaces the outcome via the typed status banner.
    /// Failures carry a Retry that re-runs this function on the same clip (audit:
    /// OCR banner renders success/failure identically; no retry on failure).
    private func runOCR(on clip: Clip) {
        ocrProcessingClipID = clip.id
        store.extractText(from: clip) { message in
            ocrProcessingClipID = nil
            let lower = message.lowercased()
            let isFailure = lower.contains("fail") || lower.contains("no image data")
            showStatusBanner(
                message,
                severity: isFailure ? .failure : .success,
                retry: isFailure ? { runOCR(on: clip) } : nil
            )
        }
    }

    private func categoriesMenu(for clip: Clip) -> some View {
        Menu("Categories") {
            ForEach(store.categories) { category in
                let categoryID = category.id ?? -1
                let isMember = store.categoryIDs(for: clip).contains(categoryID)
                Button {
                    if isMember {
                        // Tapping a member category removes the clip from it.
                        store.setClip(clip, inCategory: categoryID, false)
                    } else if let clipID = clip.id {
                        // Filing routes through fileClip so single-membership mode
                        // clears the other categories; multiple-mode stays additive.
                        store.fileClip(id: clipID, intoCategory: categoryID)
                    }
                } label: {
                    if isMember {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
            Divider()
            Button("New Category...") { categoryCreationClip = clip }
        }
    }

    // MARK: - Empty and footer

    /// Standardized empty state. The no-results variant carries a Clear search
    /// action so the user is never stranded (audit: empty states inconsistent;
    /// empty search state has no CTA to clear query).
    @ViewBuilder
    private var emptyState: some View {
        if !store.query.isEmpty {
            ContentUnavailableView {
                Label("No clips match \"\(store.query)\"", systemImage: "magnifyingglass")
            } description: {
                Text("Try a different search or clear it to see everything.")
            } actions: {
                Button("Clear search") { store.query = "" }
            }
        } else {
            switch selection {
            case .history:
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "clipboard",
                    description: Text("Copy something and it will show up.")
                )
            case .category:
                ContentUnavailableView(
                    "No clips in this category",
                    systemImage: "tray",
                    description: Text("Right-click a clip and choose Categories, or drag a card onto the category.")
                )
            case .onePassword:
                ContentUnavailableView(
                    "No secrets shared to Clippy yet",
                    systemImage: "key.fill"
                )
            // .scripts and .assistant route to their own views; unreachable here.
            case .scripts, .assistant:
                ContentUnavailableView("", systemImage: "tray")
            }
        }
    }

    // MARK: - Batch action bar

    /// Shown above the footer when 2+ clips are selected. Operates on
    /// `actionableClips` so it tracks the live multi-selection.
    private var batchActionBar: some View {
        HStack(spacing: 10) {
            batchButton("Paste Seq.", "list.number") {
                onPasteMany(actionableClips, false, settings.pastePlainTextByDefault)
            }
            batchButton("Paste Joined", "rectangle.compress.vertical") {
                onPasteMany(actionableClips, true, settings.pastePlainTextByDefault)
            }
            batchButton("Delete", "trash") { requestBatchDelete() }
            batchButton("AI Titles", "sparkles") { runBatchAITitles() }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    private func batchButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(PanelTypography.metadata(settings))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if selectedClipIDs.count >= 2 {
                Text("\(selectedClipIDs.count) selected")
                    .font(PanelTypography.micro(settings))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(tokens.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(tokens.accent)
            }
            keyHint("\u{21A9}", settings.pastePlainTextByDefault ? "paste plain" : "paste")
            keyHint("\u{21E7}\u{21A9}", settings.pastePlainTextByDefault ? "formatted" : "plain")
            keyHint("\u{2318}P", "pin")
            keyHint("\u{2318}E", "edit")
            keyHint("\u{2318}\u{232B}", "delete")
            // Reflect the pinned state in the footer so Escape's behavior is not
            // mislabeled (audit: pinned panel silently ignores Escape). When
            // pinned, Escape is disabled at the panel level, so advertise that
            // instead of "close".
            keyHint("\u{238B}", settings.panelPinned ? "pinned" : "close")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                // Use an explicit system font so key glyphs always render at the
                // correct weight, regardless of any custom font family chosen in
                // user appearance settings.
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(tokens.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tokens.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textPrimary.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(action)")
    }

    /// Slim error bar with a Retry button for search/observation failures (audit:
    /// search failures silently swallowed; observation errors only logged).
    private func errorBanner(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.danger)
            Text(message)
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(2)
            Spacer()
            Button("Retry") { retry() }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.danger)
                .font(PanelTypography.metadata(settings).weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tokens.danger.opacity(0.12))
    }

    // MARK: - Selection and actions

    private var selectedClip: Clip? {
        visibleClips.indices.contains(selectedIndex) ? visibleClips[selectedIndex] : nil
    }

    private func moveSelection(by delta: Int) {
        guard !visibleClips.isEmpty else { return }
        selectedIndex = max(0, min(visibleClips.count - 1, selectedIndex + delta))
    }

    /// Shift+Arrow extension of the multi-selection from the keyboard anchor.
    /// Seeds the set with the anchor (so a single selection becomes a visible
    /// multi-selection) then adds every clip between the anchor and the new
    /// index (audit: keyboard arrows cannot extend multi-selection).
    private func extendSelection(by delta: Int) {
        guard !visibleClips.isEmpty else { return }
        let oldIndex = selectedIndex
        let newIndex = max(0, min(visibleClips.count - 1, oldIndex + delta))
        if selectedClipIDs.isEmpty,
           let anchorID = visibleClips.indices.contains(oldIndex) ? visibleClips[oldIndex].id : nil {
            selectedClipIDs.insert(anchorID)
        }
        let lo = min(oldIndex, newIndex), hi = max(oldIndex, newIndex)
        for i in lo...hi {
            if let id = visibleClips[i].id { selectedClipIDs.insert(id) }
        }
        selectedIndex = newIndex
    }

    /// Single-click selection with macOS modifier semantics:
    /// - Cmd: toggle this clip in/out of the multi-selection.
    /// - Shift: extend the multi-selection from the anchor (`selectedIndex`) to here.
    /// - Plain: clear the multi-selection and anchor on this clip.
    /// In every case `selectedIndex` is moved to the clicked row so the keyboard
    /// anchor and Return-to-paste stay in sync with the mouse. Focus is
    /// re-asserted so card actions do not strand keyboard users (audit: focus
    /// loss strands keyboard user).
    private func handleRowClick(_ clip: Clip, at index: Int, modifiers: EventModifiers) {
        guard let id = clip.id else { return }
        if modifiers.contains(.command) {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) }
            selectedIndex = index
        } else if modifiers.contains(.shift) {
            guard !visibleClips.isEmpty else { return }
            let upper = visibleClips.count - 1
            let lo = max(0, min(selectedIndex, index))
            let hi = min(upper, max(selectedIndex, index))
            let rangeIDs = visibleClips[lo...hi].compactMap { $0.id }
            selectedClipIDs.formUnion(rangeIDs)
            selectedIndex = index
        } else {
            selectedClipIDs = []          // plain click clears multi-select
            selectedIndex = index
        }
        searchFocused = true
    }

    private func pasteSelected(shiftHeld: Bool) {
        // Multi-selection routes Return to the sequential batch paste so the
        // whole selection is honored, not just the anchored clip (audit: Return
        // pastes only the anchored clip even with multi-selection).
        if selectedClipIDs.count >= 2 {
            let clips = actionableClips
            guard !clips.isEmpty else { return }
            let asPlainText = settings.pastePlainTextByDefault != shiftHeld
            onPasteMany(clips, false, asPlainText)
            return
        }
        guard let clip = selectedClip else { return }
        if shiftHeld {
            // Shift+Return always inverts the default paste mode (explicit paste).
            let asPlainText = settings.pastePlainTextByDefault != shiftHeld
            onPaste(clip, asPlainText)
        } else {
            // Plain Return follows the primary action (respects copy-only toggle).
            onPrimary(clip)
        }
    }
}

// MARK: - Within-category reorder modifier

/// Applied to every clip card in the list. Owns the single .draggable for
/// each row so there is never more than one drag payload per view (SwiftUI
/// only honours the innermost payload when multiple .draggable modifiers are
/// stacked, silently discarding the rest).
///
/// - History pane (categoryID == nil): emits "clip:<id>" so CategorySidePane's
///   drop can file the clip by matching the TYPE TAG, never by comparing the
///   integer to known category IDs.
/// - Category pane (categoryID set): emits "reorder:clip:<id>" (kind "clip") so
///   CategorySidePane's drop can distinguish this from category-reorder tokens
///   ("reorder:cat:<id>") purely by tag, with no value-based id check.
///   Within-list reorder also uses kind "clip" and only accepts "reorder:clip:<id>".
private struct CategoryReorderModifier: ViewModifier {
    let clipID: Int64
    let categoryID: Int64?
    @Binding var draggingOverClipID: Int64?
    let store: ClipStore

    func body(content: Content) -> some View {
        guard let categoryID else {
            // History pane: "clip:<id>" payload so CategorySidePane's drop handler
            // can branch on the TYPE TAG rather than checking whether the integer
            // matches a known category. A clip whose Int64 id happens to equal an
            // existing category id would otherwise be silently rejected.
            return AnyView(content.draggable("clip:\(clipID)"))
        }
        return AnyView(
            content
                // "clip" kind tag so CategorySidePane's drop can distinguish
                // "reorder:clip:<id>" from "reorder:cat:<id>" by TAG alone.
                // Previously both used plain "reorder:<id>", requiring a
                // store.categories.contains() value check that silently misfired
                // when clip.id happened to equal a category id.
                .reorderDraggable(id: clipID, kind: "clip")
                .reorderDropDestination(
                    id: clipID,
                    kind: "clip",
                    draggingOver: $draggingOverClipID
                ) { draggedID, targetID in
                    store.moveClip(draggedID, inCategory: categoryID, before: targetID)
                }
        )
    }
}
