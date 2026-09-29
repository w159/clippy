import SwiftUI
import AppKit

// Shell composition for `ClipListView`: header, sidebar split, command
// palette wiring and the status/notification hooks, kept out of the main file.

extension ClipListView {
    /// Section title shown in the header.
    var sectionTitle: String {
        switch selection {
        case .history: return "History"
        case .category(let id): return store.categories.first { $0.id == id }?.name ?? "Category"
        case .onePassword: return "1Password"
        case .scripts: return "Scripts"
        case .assistant: return "Assistant"
        case .aiActions: return "AI Actions"
        case .suggestions: return "Suggestions"
        case .snippets: return "Snippets"
        case .pasteStack: return "Paste Stack"
        }
    }

    /// Title bar with drag region, section title, count and quick toggles.
    var panelHeader: some View {
        PanelHeaderView(
            sectionTitle: sectionTitle,
            clipCount: SearchFieldPolicy.showsSearchField(for: selection) ? visibleClips.count : nil,
            isPinned: settings.panelPinned,
            onTogglePin: { settings.panelPinned.toggle() },
            onToggleSidebar: { NotificationCenter.default.post(name: .clippyToggleSidebar, object: nil) },
            onOpenSettings: onOpenSettings,
            onClose: onClose
        )
    }

    /// Persistent banners for search and observation failures, each with Retry.
    @ViewBuilder
    var errorBanners: some View {
        if let message = store.searchError {
            ClippyBanner(message, severity: .danger, actionTitle: "Retry", action: { store.retrySearch() })
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
        if let message = store.observationError {
            ClippyBanner(message, severity: .danger, actionTitle: "Retry", action: { store.retryObservation() })
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    /// Sidebar and main pane in the resizable, collapsible split.
    var splitContent: some View {
        SidebarSplitView(
            minContentWidth: GridMetrics.minCardWidth + GridMetrics.listPadding * 2 + GridMetrics.spacing,
            sidebar: { isRail in
                CategorySidePane(store: store, selection: $selection, isRail: isRail, smartCollections: smartCollections)
            },
            content: { mainWithFeatures }
        )
    }

    /// Command palette overlay, shown by Cmd+K.
    @ViewBuilder
    var paletteOverlay: some View {
        if paletteVisible {
            CommandPaletteHost(commands: BuiltInCommands.all(commandContext), onDismiss: closePalette)
        }
    }

    /// Hidden Cmd+K trigger.
    var paletteShortcut: some View {
        Button("Command Palette") { paletteVisible.toggle() }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// Closes the palette and returns focus to the search field.
    func closePalette() {
        paletteVisible = false
        focusTarget = .search
    }

    /// Closures the built-in commands run, bound to the current selection.
    var commandContext: PanelCommandContext {
        let clip = selectedClip
        let grid = GridPreferences.shared
        return PanelCommandContext(
            hasSelectedClip: clip != nil,
            hasQuery: !store.query.isEmpty,
            canExtractText: clip?.contentKind == .image,
            canFindSimilar: settings.suggestionsEnabled && clip?.contentKind == .text,
            isPinned: clip.map { store.isPinned($0) } ?? false,
            paste: { if let clip { onPaste(clip, settings.pastePlainTextByDefault) } },
            pastePlain: { if let clip { onPaste(clip, true) } },
            togglePin: { if let clip { store.togglePin(clip) } },
            deleteSelection: { if let clip { requestDelete(clip) } },
            findSimilar: { if let clip { store.findSimilar(to: clip); selection = .suggestions } },
            openSettings: onOpenSettings,
            toggleSidebar: { NotificationCenter.default.post(name: .clippyToggleSidebar, object: nil) },
            currentDensity: grid.density,
            setDensity: { grid.density = $0 },
            suggestionsEnabled: settings.suggestionsEnabled,
            toggleSuggestions: { settings.suggestionsEnabled.toggle() },
            clearSearch: { store.query = "" },
            extractText: { if let clip { runOCR(on: clip) } },
            newCategory: { categoryCreationClip = clip },
            featureCommands: featurePaletteCommands
        )
    }
}
