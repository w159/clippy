import SwiftUI
import AppKit

/// Transient state for the feature integrations (sheets, preview column width, auto-file tray, smart filter).
struct ClipListFeatureState {
    var transformClip: Clip?
    var translateClip: Clip?
    var describeClip: Clip?
    var panelWidth: CGFloat = 0
    /// Clips of the selected smart collection; nil when no smart collection filters History.
    var smartClips: [Clip]?
    var autoFileClipID: Int64?
    var autoFileItems: [AutoFileTrayItem] = []
    var autoFileContentKey = ""
}

/// Sheets, geometry and background refresh hooks for the features. Stateless apart from the bindings it receives.
struct ClipListFeatureModifier: ViewModifier {
    @ObservedObject var store: ClipStore
    @ObservedObject var smartCollections: SmartCollectionSelection
    @Binding var features: ClipListFeatureState
    let selectedClip: Clip?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { features.panelWidth = $0 }
            .sheet(item: $features.transformClip) { clip in
                TransformPickerView(clip: clip, sink: ClipStoreTransformSink(store: store, clip: clip),
                                    onClose: { features.transformClip = nil })
            }
            .sheet(item: $features.translateClip) { clip in
                TranslateClipSheet(clipID: clip.id ?? -1, text: clip.contentText,
                                   isSensitive: SensitiveContent.isSensitive(clip: clip), sink: ClipStoreTranslateSink(store: store))
            }
            .sheet(item: $features.describeClip) { clip in
                if let url = store.imageURL(for: clip) {
                    DescribeImageSheet(imageURL: url, isSensitive: SensitiveContent.isSensitive(clip: clip),
                                       onSaveAsClip: { store.saveDerivedText($0, source: "Clippy Vision") })
                }
            }
            .onChange(of: smartCollections.selectedID) { _, _ in refreshSmartClips() }
            .onChange(of: store.clips) { _, _ in refreshSmartClips() }
            .task(id: selectedClip?.id) { await refreshAutoFile() }
    }

    private func refreshSmartClips() {
        features.smartClips = smartCollections.activeRule == nil ? nil : smartCollections.selectedClips()
    }

    /// Passive suggestion for the selected uncategorized text clip; runs only with the auto-file opt-in.
    private func refreshAutoFile() async {
        features.autoFileItems = []
        features.autoFileClipID = nil
        guard SemanticSearchPreferences.standard.isAutoFileEnabled, let clip = selectedClip, clip.contentKind == .text,
              store.categoryIDs(for: clip).isEmpty, let mapped = ClipDatabaseAutoFileSource.autoFileClip(clip) else { return }
        guard let found = await AutoFileService.shared.suggestion(for: mapped, database: store.database, force: false),
              !Task.isCancelled else { return }
        features.autoFileContentKey = mapped.contentKey
        features.autoFileItems = trayItems(for: found)
        features.autoFileClipID = clip.id
    }

    private func trayItems(for suggestion: AutoFileSuggestion) -> [AutoFileTrayItem] {
        let name = store.categories.first { $0.id == suggestion.categoryID }?.name ?? "Category"
        return [AutoFileTrayItem(suggestion: suggestion, categoryName: name)]
    }
}

extension ClipListView {
    // MARK: - Layout

    /// Main pane, auto-file tray and optional preview column (wide panel only).
    var mainWithFeatures: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                mainPane
                autoFileTray
            }
            if showsPreviewColumn {
                ClipPreviewColumn(
                    clip: selectedClip, query: store.query,
                    onQuickLook: { if let clip = selectedClip { QuickLookController.shared.toggle(for: clip) } },
                    onPaste: { if let clip = selectedClip { onPaste(clip, settings.pastePlainTextByDefault) } })
            }
        }
    }

    /// True when the preview column is on, the panel is wide enough and the pane lists clips.
    var showsPreviewColumn: Bool {
        guard PreviewColumnPreferences.isVisible(panelWidth: features.panelWidth, enabled: previewColumnEnabled) else { return false }
        switch selection {
        case .history, .category, .suggestions: return true
        default: return false
        }
    }

    @ViewBuilder
    var autoFileTray: some View {
        if let clip = selectedClip, clip.id == features.autoFileClipID, !features.autoFileItems.isEmpty {
            AutoFileTray(items: features.autoFileItems, onAccept: acceptAutoFile, onDismiss: dismissAutoFile)
        }
    }

    private func acceptAutoFile(_ suggestion: AutoFileSuggestion) {
        store.fileClip(id: suggestion.clipID, intoCategory: suggestion.categoryID)
        features.autoFileItems = []
    }

    private func dismissAutoFile(_ suggestion: AutoFileSuggestion) {
        AutoFileService.shared.dismiss(suggestion, contentKey: features.autoFileContentKey)
        features.autoFileItems = []
    }

    /// Explicit "Suggest Category": works without the passive opt-in, but never for sensitive or non-text clips.
    func requestAutoFile(_ clip: Clip) {
        guard ClipFeatureMenuPolicy.items(for: clip).contains(.suggestCategory),
              let mapped = ClipDatabaseAutoFileSource.autoFileClip(clip) else { return }
        Task { @MainActor in
            let found = await AutoFileService.shared.suggestion(for: mapped, database: store.database, force: true)
            guard let found else { showStatusBanner("No category suggestion for this clip."); return }
            let name = store.categories.first { $0.id == found.categoryID }?.name ?? "Category"
            features.autoFileContentKey = mapped.contentKey
            features.autoFileItems = [AutoFileTrayItem(suggestion: found, categoryName: name)]
            features.autoFileClipID = clip.id
        }
    }

    // MARK: - History smart filter

    /// Applies the selected smart collection to the History list.
    func smartFiltered(_ base: [Clip]) -> [Clip] {
        guard let smart = features.smartClips else { return base }
        if store.query.isEmpty { return smart.filter { !store.isPinned($0) } }
        let ids = Set(smart.compactMap(\.id))
        return base.filter { $0.id.map(ids.contains) ?? false }
    }

    // MARK: - Keyboard

    /// Space toggles Quick Look for the selected clip while the list (not a text field) has focus.
    func handleQuickLookKey(_ press: KeyPress, source: PanelFocusTarget) -> KeyPress.Result? {
        guard press.key == .space, press.modifiers.isEmpty, source == .list, let clip = selectedClip else { return nil }
        QuickLookController.shared.toggle(for: clip)
        return .handled
    }

    // MARK: - Actions

    func saveAsSnippet(_ clip: Clip) {
        guard ClipFeatureMenuPolicy.items(for: clip).contains(.saveSnippet) else { return }
        do {
            try SnippetStore.shared.add(Snippet(title: clip.userTitle ?? String(clip.previewText.prefix(40)), body: clip.contentText))
            showStatusBanner("Saved as snippet. Add an abbreviation in Snippets.", severity: .success)
        } catch {
            showStatusBanner("Could not save the snippet.", severity: .failure)
        }
    }

    func quickTransform(_ clip: Clip, id: String) {
        guard ClipFeatureMenuPolicy.items(for: clip).contains(.transform), let item = TransformRegistry.transform(id: id) else { return }
        do {
            store.saveDerivedText(try item.transform(clip.contentText), source: "Clippy Transform")
            showStatusBanner("Saved \(item.title) result as a new clip.", severity: .success)
        } catch {
            showStatusBanner("That transform could not be applied.", severity: .failure)
        }
    }

    func presentTransform(_ clip: Clip) {
        if ClipFeatureMenuPolicy.items(for: clip).contains(.transform) { features.transformClip = clip }
    }

    // MARK: - Palette

    /// Palette commands contributed by the features. Sensitive selections disable everything except Quick Look's own guard.
    var featurePaletteCommands: [any PaletteCommand] {
        let clip = selectedClip
        let allowed = clip.map { ClipFeatureMenuPolicy.items(for: $0) } ?? []
        let usable = allowed.isEmpty ? nil : clip
        let isText = usable?.contentKind == .text
        var commands: [any PaletteCommand] = PreviewPaletteCommands.commands(selectedClip: usable)
        commands += PasteStackCommands.make(
            selectedClips: { actionableClips.filter { !ClipFeatureMenuPolicy.items(for: $0).isEmpty } },
            database: { store.database })
        commands += SnippetTransformIntegration.paletteCommands(
            clip: usable, transform: presentTransform, newSnippet: saveAsSnippet, searchSnippets: { selection = .snippets })
        commands += SemanticIntegration.paletteCommands(
            hasSelection: isText, hasImageSelection: usable?.contentKind == .image,
            translate: { if let usable, isText { features.translateClip = usable } },
            describe: { if let usable, usable.contentKind == .image { features.describeClip = usable } },
            suggestCategory: { if let usable { requestAutoFile(usable) } })
        return commands
    }

    // MARK: - Context menu

    /// Feature items for a single clip; empty for sensitive clips.
    @ViewBuilder
    func featureMenuItems(for clip: Clip) -> some View {
        let allowed = ClipFeatureMenuPolicy.items(for: clip)
        if !allowed.isEmpty {
            Divider()
            if allowed.contains(.quickLook) {
                Button { QuickLookController.shared.toggle(for: clip) } label: { Label("Quick Look", systemImage: "eye") }
            }
            if allowed.contains(.pasteStack) {
                pasteStackMenuItems(for: clip, selection: actionableClips, database: store.database)
            }
            if allowed.contains(.appendClipboard) {
                Button("Append Clipboard to Clip") { ClipMergeActions.appendClipboard(to: clip, database: store.database) }
            }
            if allowed.contains(.transform) {
                SnippetTransformIntegration.menuItems(
                    for: clip, openPicker: presentTransform, quick: quickTransform, saveAsSnippet: saveAsSnippet)
            }
            if allowed.contains(.translate) || allowed.contains(.describeImage) {
                SemanticIntegration.menuItems(
                    for: clip, translate: { features.translateClip = clip }, describe: { features.describeClip = clip },
                    suggestCategory: { requestAutoFile(clip) })
            }
        }
    }

    /// Extra batch items: merge and add-to-stack over the non-sensitive part of the selection.
    @ViewBuilder
    func batchFeatureMenuItems() -> some View {
        let eligible = ClipMergeActions.eligible(actionableClips)
        Divider()
        Button("Merge \(eligible.count) Clips") { ClipMergeActions.mergeSelected(eligible, database: store.database) }
            .disabled(eligible.count < 2)
        Button("Add \(eligible.count) to Paste Stack") { eligible.forEach { PasteStackController.shared.add($0) } }
            .disabled(eligible.isEmpty)
    }
}
